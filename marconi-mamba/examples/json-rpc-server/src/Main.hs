{-
-- Sample JSON-RPC server program
--
-- Often we need to test the JSON-RPC http server without the cermony of marconi, or marconi mamba.
-- The purpose of this exampl JSON-RPC server is to test the cold-store, SQLite, flow.
-- The assumption is that at some point in the past marconi had been executed and there is SQLite databse available
-- The server uses CLI parameters to connect to SQLite
-- See `start-json-rpc-server.sh` for detail
-}
module Main where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (race_)
import Control.Concurrent.STM (atomically)
import Control.Lens.Operators ((^.))
import Options.Applicative (Parser, execParser, help, helper, info, long, metavar, short, strOption, (<**>))

import Marconi.Api.Types (UtxoIndexerEnv, queryEnv, uiIndexer)
import Marconi.Api.UtxoIndexersQuery qualified as UIQ
import Marconi.Bootstrap (bootstrapHttp, bootstrapJsonRpc)
import Marconi.CLI (multiString)
import Marconi.Index.Utxo qualified as Utxo
import Marconi.Types (TargetAddresses)


data CliOptions = CliOptions
    { _utxoPath  :: FilePath -- ^ path to utxo sqlite database
    , _addresses :: TargetAddresses
    }

cliParser :: Parser CliOptions
cliParser = CliOptions
    <$> strOption (long "utxo-db"
                              <> short 'd'
                              <> metavar "FILENAME"
                              <> help "Path to the utxo SQLite database.")
     <*> multiString (long "addresses-to-index"
                        <> help ("Bech32 Shelley addresses to index."
                                 <> " i.e \"--address-to-index address-1 --address-to-index address-2 ...\"" ) )

main :: IO ()
main = do
    (CliOptions dbpath addresses) <- execParser $ info (cliParser <**> helper) mempty
    putStrLn $ "Starting the Example RPC http-server:"
        <>"\nport =" <> show (3000 :: Int)
        <> "\nmarconi-db-dir =" <> dbpath
        <> "\nnumber of addresses to index = " <> show (length addresses)
    env <- bootstrapJsonRpc Nothing addresses
    race_ (bootstrapHttp env) (mocUtxoIndexer dbpath (env ^. queryEnv) )

-- | moc marconi utxo indexer.
-- This will allow us to use the UtxoIndexer query interface without having cardano-node or marconi online
-- Effectively we are going to query SQLite only
mocUtxoIndexer :: FilePath -> UtxoIndexerEnv -> IO ()
mocUtxoIndexer dbpath env =
        Utxo.open dbpath (Utxo.Depth 4) >>= callback >> innerLoop
    where
      callback :: Utxo.UtxoIndexer -> IO ()
      callback = atomically . UIQ.writeTMVar' (env ^. uiIndexer)
      innerLoop = threadDelay 1000000 >> innerLoop -- create some latency
