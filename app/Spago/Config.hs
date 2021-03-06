module Spago.Config
  ( makeConfig
  , ensureConfig
  , addDependencies
  , Config(..)
  ) where

import           Spago.Prelude

import qualified Data.List          as List
import qualified Data.Map           as Map
import qualified Data.Sequence      as Seq
import qualified Data.Text.Encoding as Text
import qualified Dhall.Import
import qualified Dhall.Map
import qualified Dhall.Parser       as Parser
import           Dhall.TypeCheck    (X)
import qualified Dhall.TypeCheck

import qualified Spago.Dhall        as Dhall
import qualified Spago.Messages     as Messages
import           Spago.PackageSet   (Package, PackageName (..), PackageSet)
import qualified Spago.PackageSet   as PackageSet
import qualified Spago.PscPackage   as PscPackage
import qualified Spago.Templates    as Templates


pathText :: Text
pathText = "spago.dhall"

-- | Path for the Spago Config
path :: FilePath
path = pathFromText pathText


-- | Spago configuration file type
data Config = Config
  { name         :: Text
  , dependencies :: [PackageName]
  , packages     :: PackageSet
  } deriving (Show, Generic)

instance ToJSON Config
instance FromJSON Config


-- | Type to represent the "raw" configuration,
--   which is a configuration which has been parsed from Dhall,
--   but not yet resolved (this is used to manipulate the AST directly)
--
--   Note: not all the values from the configuration are included here.
--
--   Note: this limits the amount of stuff that one can do in Dhall inside
--   the configuration. E.g. you won't be able to have a dependency that
--   is not a string in the list of dependencies of the project.
data RawConfig = RawConfig
  { rawName :: Text
  , rawDeps :: [PackageName]
  -- TODO: add packages if needed
  } deriving (Show, Generic)


-- | Tries to read in a Spago Config
parseConfig :: Spago m => Text -> m Config
parseConfig dhallText = do
  expr <- liftIO $ Dhall.inputExpr dhallText
  case expr of
    Dhall.RecordLit ks -> do
      maybeConfig <- pure $ do
        let packageTyp      = Dhall.genericAuto :: Dhall.Type Package
            packageNamesTyp = Dhall.list (Dhall.auto :: Dhall.Type PackageName)
        name         <- Dhall.requireTypedKey ks "name" Dhall.strictText
        dependencies <- Dhall.requireTypedKey ks "dependencies" packageNamesTyp
        packages     <- Dhall.requireKey ks "packages" $ \case
          Dhall.RecordLit pkgs -> (Map.mapKeys PackageName . Dhall.Map.toMap)
            <$> traverse (Dhall.coerceToType packageTyp) pkgs
          something -> Left $ Dhall.PackagesIsNotRecord something

        Right $ Config{..}

      case maybeConfig of
        Right config -> pure config
        Left err     -> throwM err
    _ -> case Dhall.TypeCheck.typeOf expr of
      Right e  -> throwM $ Dhall.ConfigIsNotRecord e
      Left err -> throwM $ err


-- | Checks that the Spago config is there and readable
ensureConfig :: Spago m => m Config
ensureConfig = do
  exists <- testfile path
  unless exists $ do
    die $ Messages.cannotFindConfig
  PackageSet.ensureFrozen
  configText <- readTextFile path
  try (parseConfig configText) >>= \case
    Right config -> pure config
    Left (err :: Dhall.ReadError X) -> throwM err


-- | Copies over `spago.dhall` to set up a Spago project.
--   Eventually ports an existing `psc-package.json` to the new config.
makeConfig :: Spago m => Bool -> m ()
makeConfig force = do
  unless force $ do
    hasSpagoDhall <- testfile path
    when hasSpagoDhall $ die $ Messages.foundExistingProject pathText
  writeTextFile path Templates.spagoDhall
  Dhall.format pathText

  -- We try to find an existing psc-package config, and we migrate the existing
  -- content if we found one, otherwise we copy the default template
  pscfileExists <- testfile PscPackage.configPath
  when pscfileExists $ do
    -- first, read the psc-package file content
    content <- readTextFile PscPackage.configPath
    case eitherDecodeStrict $ Text.encodeUtf8 content of
      Left err -> echo $ Messages.failedToReadPscFile err
      Right pscConfig -> do
        echo "Found a \"psc-package.json\" file, migrating to a new Spago config.."
        -- update the project name
        withConfigAST $ \config -> config { rawName = PscPackage.name pscConfig }
        -- try to update the dependencies (will fail if not found in package set)
        let pscPackages = map PackageName $ PscPackage.depends pscConfig
        config <- ensureConfig
        addDependencies config pscPackages


-- | Takes a function that manipulates the Dhall AST of the Config,
--   and tries to run it on the current config.
--   If it succeeds, it writes back to file the result returned.
--   Note: it will pass in the parsed AST, not the resolved one (so
--   e.g. imports will still be in the tree). If you need the resolved
--   one, use `ensureConfig`.
withConfigAST :: Spago m => (RawConfig -> RawConfig) -> m ()
withConfigAST transform = do
  -- get a workable configuration
  exists <- testfile path
  unless exists $ makeConfig False
  configText <- readTextFile path

  -- parse the config without resolving imports
  (header, expr) <- case Parser.exprAndHeaderFromText mempty configText of
    Left  err -> throwM err
    Right (header, ast) -> case Dhall.denote ast of
      -- remove Note constructors, and check if config is a record
      Dhall.RecordLit ks -> do
        rawConfig <- pure $ do
          currentName <- Dhall.requireKey ks "name" Dhall.fromTextLit
          currentDeps <- Dhall.requireKey ks "dependencies" toPkgsList
          Right $ RawConfig currentName currentDeps

        -- apply the transformation if config is valid
        RawConfig{..} <- case rawConfig of
          Right conf -> pure $ transform conf
          Left err   -> die $ Messages.failedToParseFile pathText err

        -- return the new AST from the new config
        let
          mkNewAST "name"         _ = Dhall.toTextLit rawName
          mkNewAST "dependencies" _ = Dhall.ListLit Nothing
            $ Seq.fromList
            $ fmap Dhall.toTextLit
            $ fmap packageName rawDeps
          mkNewAST _ v = v
        pure (header, Dhall.RecordLit $ Dhall.Map.mapWithKey mkNewAST ks)

      e -> throwM $ Dhall.ConfigIsNotRecord e

  -- After modifying the expression, we have to check if it still typechecks
  -- if it doesn't we don't write to file
  resolvedExpr <- liftIO $ Dhall.Import.load expr
  case Dhall.TypeCheck.typeOf resolvedExpr of
    Left  err -> throwM err
    Right _   -> do
      writeTextFile path $ Dhall.prettyWithHeader header expr <> "\n"
      Dhall.format pathText

  where
    toPkgsList
      :: (Pretty a, Typeable a)
      => Dhall.Expr Parser.Src a
      -> Either (Dhall.ReadError a) [PackageName]
    toPkgsList (Dhall.ListLit _ pkgs) =
      let
        texts = fmap Dhall.fromTextLit $ toList pkgs
      in
      case (lefts texts) of
        []  -> Right $ fmap PackageName $ rights texts
        e:_ -> Left e
    toPkgsList e = Left $ Dhall.DependenciesIsNotList e


addRawDeps :: [PackageName] -> RawConfig -> RawConfig
addRawDeps newDeps config = config
  { rawDeps = List.sort $ List.nub (newDeps <> (rawDeps config)) }

-- | Try to add the `newPackages` to the "dependencies" list in the Config.
--   It will not add any dependency if any of them is not in the package set.
--   If everything is fine instead, it will add the new deps, sort all the
--   dependencies, and write the Config back to file.
addDependencies :: Spago m => Config -> [PackageName] -> m ()
addDependencies config newPackages = do
  let notInPackageSet = mapMaybe
        (\p -> case Map.lookup p (packages config) of
                Just _  -> Nothing
                Nothing -> Just p)
        newPackages
  case notInPackageSet of
    -- If none of the newPackages are outside of the set, add them to existing dependencies
    []   -> withConfigAST $ addRawDeps newPackages
    pkgs -> echo $ Messages.failedToAddDeps $ map packageName pkgs
