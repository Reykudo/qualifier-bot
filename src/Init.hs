{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}

module Init where

-- import Api (app)
-- import Api.User (generateJavaScript)

import Bot.Models (doMigrations)
import Bot.UpdateHandler (updateHandler)
import Bot.UpdateLoop (updateLoop)
import Config (App, AppT (runAppT), Config (..), Environment (..), makePool, setLogger)
import Control.Concurrent (killThread)
import Control.Exception.Safe
import Control.Monad.Except (runExceptT)
import Control.Monad.Logger
import qualified Control.Monad.Metrics as M
import Control.Monad.Reader (ReaderT (runReaderT))
import Data.Monoid
import qualified Data.Pool as Pool
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text as Text
import Data.Typeable
import Database.Persist.Postgresql (runSqlPool)
import qualified Katip
import Lens.Micro ((^.))
import Logger (defaultLogEnv)
import Network.Wai (Application)
import Network.Wai.Handler.Warp (run)
import Network.Wai.Metrics (metrics, registerWaiMetrics)
import Safe (readMay)
import Say
import System.Environment (lookupEnv)
import System.Remote.Monitoring (forkServer, serverMetricStore, serverThreadId)
import UnliftIO (MonadIO (liftIO), MonadUnliftIO, UnliftIO (unliftIO))
import Web.Telegram.API (Token (..))

-- | An action that creates a WAI 'Application' together with its resources,
--   runs it, and tears it down on exit
runAppDevel :: IO ()
runAppDevel = do
  say "in runAppDevel"
  withConfig $ \config -> do
    say "acquired config"
    initialize config `finally` say "exited: initialize config"

-- say "post-initialize"
-- run (configPort config) cfg
--   `finally` say "server is closed"

-- | The 'initialize' function accepts the required environment information,
-- initializes the WAI 'Application' and returns it
initialize cfg = do
  do
    say "initialize"
    -- waiMetrics <- registerWaiMetrics (configMetrics cfg ^. M.metricsStore)
    say "wai metrics"
    let logger = setLogger (configEnv cfg)
    say "run migrations"
    liftIO $
      bracket (say "starting to run migrations") (\_ -> say "migrations complete") $
        ( \_ -> do
            say "actually running migrations"
            runSqlPool doMigrations (configPool cfg) `catch` \(SomeException e) -> do
              say $
                mconcat
                  [ "exception in doMigrations, type: ",
                    tshow (typeOf e),
                    ", shown: ",
                    tshow e
                  ]
              throwIO e
            say "okay all done"
            -- pure $ pure ()
        )
    say "making app"
    let withRunInIO = \runInIO -> do
          updateLoop cfg (runInIO . updateHandler)
    withRunInIO
      ( \appT -> do
          runExceptT $ runReaderT (runAppT appT) cfg
          pure ()
      )

withConfig :: MonadIO m => (Config -> IO a) -> m a
withConfig action = liftIO $ do
  say "acquireConfig"
  port <- lookupSetting "PORT" 8081
  say $ "on port:" <> tshow port
  env <- lookupSetting "ENV" Development
  token <- lookupSetting "TG_BOT_QUALIFIER_TOKEN" ""
  maxHandlers <- lookupSetting "MAX_HANDLERS" 20
  say $ "on env: " <> tshow env
  bracket defaultLogEnv (\x -> say "closing katip scribes" >> Katip.closeScribes x) $ \logEnv -> do
    say "got log env"
    !pool <- makePool env logEnv `onException` say "exception in makePool"
    say "got pool "
    bracket (forkServer "localhost" 8082) (\x -> say "closing ekg" >> do killThread $ serverThreadId x) $ \ekgServer -> do
      say "forked ekg server"
      let store = serverMetricStore ekgServer
      waiMetrics <- registerWaiMetrics store `onException` say "exception in registerWaiMetrics"
      say "registered wai metrics"
      metr <- M.initializeWith store
      say "got metrics"
      action
        Config
          { configPool = pool,
            configEnv = env,
            -- , configMetrics = metr
            configLogEnv = logEnv,
            configPort = port,
            configEkgServer = serverThreadId ekgServer,
            configToken = Token $ T.pack token,
            configTgMaxHandlers = maxHandlers
          }

-- | Takes care of cleaning up 'Config' resources
shutdownApp :: Config -> IO ()
shutdownApp cfg = do
  Katip.closeScribes (configLogEnv cfg)
  Pool.destroyAllResources (configPool cfg)
  -- Monad.Metrics does not provide a function to destroy metrics store
  -- so, it'll hopefully get torn down when async exception gets thrown
  -- at metrics server process
  killThread (configEkgServer cfg)
  pure ()

-- | Looks up a setting in the environment, with a provided default, and
-- 'read's that information into the inferred type.
lookupSetting :: Read a => String -> a -> IO a
lookupSetting env def = do
  maybeValue <- lookupEnv env
  case maybeValue of
    Nothing ->
      return def
    Just str ->
      maybe (handleFailedRead str) return (readMay str)
  where
    handleFailedRead str =
      error $
        mconcat
          [ "Failed to read [[",
            str,
            "]] for environment variable ",
            env
          ]

tshow :: Show a => a -> Text
tshow = Text.pack . show