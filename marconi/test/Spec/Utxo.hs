{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

{-# OPTIONS_GHC -Wno-orphans #-}

module Spec.Utxo (tests) where

import Control.Lens (filtered, folded, toListOf, traversed)
import Control.Lens.Operators ((%~), (^.))
import Control.Monad.IO.Class (liftIO)
import Data.ByteString (ByteString)
import Data.List (nub, sort)
import Data.List.NonEmpty (nonEmpty, toList)
import Data.Maybe (fromJust, mapMaybe)
import Data.Proxy (Proxy (Proxy))
import Data.Set (Set)
import Data.Set qualified as Set
import Database.SQLite.Simple qualified as SQL
import Hedgehog (Gen, Property, forAll, property, (===))
import Hedgehog qualified
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testPropertyNamed)

import Cardano.Api qualified as C
import Gen.Cardano.Api.Typed qualified as CGen
import Marconi.Index.Utxo qualified as Utxo
import Marconi.Types (CurrentEra, TargetAddresses)
import RewindableIndex.Storable (StorableEvent, StorableQuery, resume)
import RewindableIndex.Storable qualified as Storable

genSlotNo :: Hedgehog.MonadGen m => m C.SlotNo
genSlotNo = C.SlotNo <$> Gen.word64 (Range.linear 10 1000)

genBlockNo :: Hedgehog.MonadGen m => m C.BlockNo
genBlockNo = C.BlockNo <$> Gen.word64 (Range.linear 100 1000)

validByteSizeLength :: Int
validByteSizeLength = 32

genBlockHeader
  :: Hedgehog.MonadGen m
  => m C.BlockNo
  -> m C.SlotNo
  -> m C.BlockHeader
genBlockHeader genB genS = do
  bs <- Gen.bytes(Range.singleton validByteSizeLength)
  sn <- genS
  bn <- genB
  let (hsh :: C.Hash C.BlockHeader) =
        fromJust $ C.deserialiseFromRawBytes(C.proxyToAsType Proxy) bs
  pure (C.BlockHeader sn hsh bn)

genChainPoint'
  :: Hedgehog.MonadGen m
  => m C.BlockNo
  -> m C.SlotNo
  -> m C.ChainPoint
genChainPoint' genB genS = do
  (C.BlockHeader sn hsh _) <- genBlockHeader genB genS
  pure $ C.ChainPoint sn hsh

genChainPoint :: Hedgehog.MonadGen m => m C.ChainPoint
genChainPoint =
  Gen.frequency
  [ (95, genChainPoint' genBlockNo genSlotNo)
  , (5, pure C.ChainPointAtGenesis)
  ]

genTxIndex :: Gen C.TxIx
genTxIndex = C.TxIx . fromIntegral <$> Gen.word16 Range.constantBounded

genUtxo :: Gen Utxo.Utxo
genUtxo = CGen.genAddressShelley >>= genUtxo' . C.toAddressAny

genUtxo' :: C.AddressAny -> Gen Utxo.Utxo
genUtxo' _address = do
  _txId             <- CGen.genTxId
  _txIx             <- genTxIndex
  sc <- CGen.genTxOutDatumHashTxContext C.BabbageEra
  let (_datum, _datumHash)  = Utxo.getScriptDataAndHash sc
  script            <- CGen.genReferenceScript C.ShelleyEra
  _value            <- CGen.genValueForTxOut
  let (_inlineScript, _inlineScriptHash)=  Utxo.getRefScriptAndHash script
  pure $ Utxo.Utxo {..}

genEventAtChainPoint :: C.ChainPoint -> Gen (Utxo.StorableEvent Utxo.UtxoHandle)
genEventAtChainPoint ueChainPoint = do
  ueUtxos <- Gen.set (Range.linear 1 3) genUtxo
  ueInputs <- Gen.set (Range.linear 1 2) CGen.genTxIn
  ueBlockNo <- genBlockNo
  pure $ Utxo.UtxoEvent {..}

genEvents :: Gen (Utxo.StorableEvent Utxo.UtxoHandle)
genEvents = do
  ueUtxos <- Gen.set (Range.linear 1 3) genUtxo
  genEvents' ueUtxos

genEvents'
  :: Set Utxo.Utxo
  -> Gen (Utxo.StorableEvent Utxo.UtxoHandle)
genEvents' ueUtxos = do
  ueInputs <- Gen.set (Range.linear 1 2) CGen.genTxIn
  ueBlockNo <- genBlockNo
  ueChainPoint <- genChainPoint
  pure $ Utxo.UtxoEvent {..}

instance Eq (Utxo.StorableEvent Utxo.UtxoHandle) where
  (Utxo.UtxoEvent u i b c) == (Utxo.UtxoEvent u' i' b' c')  =
    u == u' && i == i' && b == b' && c == c'

instance Ord (Utxo.StorableEvent Utxo.UtxoHandle) where
  compare l r = Utxo.ueChainPoint l `compare` Utxo.ueChainPoint r

-- | Proves two list are equivalant, but not identical

-- NOTE --
-- | UtxoEvents equivalent relationship
-- Not all utxoEvent attributes have defined `Eq` and/or `Ord` relationship defined.
-- As events are disassembled and reassembled, the Ordering of these sub-parts may change in the coresponding collections.
-- Therefore we used the Equivalence relationship to show two event are morally equal.
--
equivalentLists :: Eq a => [a] -> [a] -> Bool
equivalentLists us us' =
  length us == length us'
  &&
  all (const True) [u `elem` us'| u <- us]
  &&
  all (const True) [u `elem` us| u <- us']

tests :: TestTree
tests = testGroup "Marconi.Utxo.Indexer.Specs are:"
    [
     testPropertyNamed "marconi-utxo split-by-address property"
     "filter UtxoEvent for Utxos with address in the TargetAddress"
     eventsAtAddressTest

    , testPropertyNamed "marconi-utxo event-to-sqlRows property"
      "Roundtrip UtxoEvents to UtxoRows converion"
     eventsToRowsRoundTripTest

    , testPropertyNamed "marconi-utxo storable-query address property"
      "Compute StorableQuery addresses from computed Utxo and generated Cardano.Api.Tx"
     txAddressToUtxoAddressTest

    , testPropertyNamed "marconi-utxo storage-roundtrip property"
      "Roundtrip storage test"
      utxoStorageTest

    , testPropertyNamed "marconi-utxo insert-query property"
      "Insert Events, and then query for events by address test"
      utxoInsertAndQueryTest

    , testPropertyNamed "marconi-utxo rewind property"
      "Insert Events, and rewind to some prvious chainpoint"
      rewindTest

    , testPropertyNamed "marconi-utxo query-interval property"
      "Insert Events, and query for the events by address and chainpoint interval"
      utxoQueryIntervalTest]


eventsToRowsRoundTripTest :: Property
eventsToRowsRoundTripTest  = property $ do
  events <- forAll $ Gen.list (Range.linear 1 5 )genEvents
  let f :: C.ChainPoint -> IO (Set C.TxIn)
      f C.ChainPointAtGenesis = pure  Set.empty
      f _                     = pure . Utxo.ueInputs $ head events
      rows = concatMap Utxo.eventsToRows events
  computedEvent <- liftIO . Utxo.rowsToEvents f $ rows
  let postGenesisEvents = filter (\e -> C.ChainPointAtGenesis /= Utxo.ueChainPoint e )  events
  length computedEvent === (length . fmap Utxo.ueChainPoint $ postGenesisEvents)
  Hedgehog.assert (equivalentLists computedEvent postGenesisEvents)

-- Insert Utxo events in storage, and retreive the events
--
utxoStorageTest :: Property
utxoStorageTest = property $ do
  events <- forAll $ Gen.list (Range.linear 1 5) genEvents
  (storedEvents :: [StorableEvent Utxo.UtxoHandle]) <-
    (liftIO . Utxo.open ":memory:") (Utxo.Depth 10)
     >>= liftIO . Storable.insertMany events
     >>= liftIO . Storable.getEvents
  Hedgehog.assert (equivalentLists storedEvents events)

-- Insert Utxo events in storage, and retrieve the events by address
--
utxoInsertAndQueryTest :: Property
utxoInsertAndQueryTest = property $ do
  events <- forAll $ Gen.list (Range.linear 1 5) genEvents
  depth <- forAll $ Gen.int (Range.linear 1 5)
  indexer <- liftIO $ Utxo.open ":memory:" (Utxo.Depth depth)
             >>= liftIO . Storable.insertMany events
  let
    qs :: [StorableQuery Utxo.UtxoHandle]
    qs = fmap (Utxo.UtxoAddress . Utxo._address) . concatMap (Set.toList . Utxo.ueUtxos) $ events
  results <- liftIO . traverse (Storable.query Storable.QEverything indexer) $ qs
  let rows = concatMap (\(Utxo.UtxoResult rs) -> rs ) results
  computedEvent <-
    liftIO . Utxo.rowsToEvents (Utxo.getTxIns (getConn indexer) ) $ rows
  Hedgehog.assert (equivalentLists
                   computedEvent
                   (filter (\e -> Utxo.ueChainPoint e /= C.ChainPointAtGenesis) events) )

-- Insert Utxo events in storage, and retreive the events by address and query interval
--
utxoQueryIntervalTest :: Property
utxoQueryIntervalTest = property $ do
  event0 <- forAll $ genEventAtChainPoint C.ChainPointAtGenesis
  event1 <- forAll $ genEventAtChainPoint (head chainpoints)
  event2 <- forAll $ genEventAtChainPoint (chainpoints !! 1)
  event3 <- forAll $ genEventAtChainPoint (chainpoints !! 2)
  let events = [event0, event1, event2, event3]
  indexer <- liftIO $ Utxo.open ":memory:" (Utxo.Depth 2)
             >>= liftIO . Storable.insertMany [event0, event1, event2, event3]
  let
    qs :: [StorableQuery Utxo.UtxoHandle]
    qs = fmap (Utxo.UtxoAddress . Utxo._address) . concatMap (Set.toList . Utxo.ueUtxos) $ events
  results <- liftIO . traverse (Storable.query (Storable.QInterval (head chainpoints)(chainpoints !! 1)) indexer) $ qs
  let rows = concatMap (\(Utxo.UtxoResult rs) -> rs ) results
  computedEvent <-
    liftIO . Utxo.rowsToEvents (Utxo.getTxIns (getConn indexer) ) $ rows
  Hedgehog.assert (equivalentLists computedEvent [event0,event1])

-- TargetAddresses are the addresses in UTXO that we filter for.
-- Puporse of this test is to filter out utxos that have a different address than those in the TargetAddress list.
eventsAtAddressTest :: Property
eventsAtAddressTest = property $ do
    event <- forAll genEvents
    let (addresses :: [StorableQuery Utxo.UtxoHandle]) =
          (traversed %~ Utxo.UtxoAddress)
          . nub
          . toListOf (folded . Utxo.address)
          . Utxo.ueUtxos
          $ event
        sameAddressEvents :: [StorableEvent Utxo.UtxoHandle]
        sameAddressEvents =  Utxo.eventsAtAddress (head addresses) [event]
        (Utxo.UtxoAddress targetAddress ) =  head addresses
        (computedAddresses :: [C.AddressAny])
          = toListOf (folded . Utxo.address)
          . concatMap (Set.toList . Utxo.ueUtxos)
          $ sameAddressEvents
        (actualAddresses :: [C.AddressAny])
          = toListOf (folded
                      . Utxo.address
                      . filtered (== targetAddress) )
            $ Utxo.ueUtxos event
    computedAddresses === actualAddresses

-- Test to make sure we only make Utxo's from chain events for the TargetAddresses user has provided through CLI
--
txAddressToUtxoAddressTest ::  Property
txAddressToUtxoAddressTest = property $ do
    t@(C.Tx (C.TxBody C.TxBodyContent{C.txOuts}) _)  <- forAll $ CGen.genTx C.BabbageEra
    let (targetAddresses :: Maybe TargetAddresses ) = mkTargetAddressFromTxOut txOuts
    let (utxos :: [Utxo.Utxo]) = Utxo.getUtxos targetAddresses t
    case targetAddresses of
        Nothing         ->  length utxos === length txOuts
        Just targets    ->
            ( nub
              . mapMaybe (\x -> addressAnyToShelley (x ^. Utxo.address))
              $ utxos) === (nub . toList $ targets)
chainpoints :: [C.ChainPoint]
chainpoints =
  let
    bs::ByteString
    bs::ByteString = "00000000000000000000000000000000"
    blockhash :: C.Hash C.BlockHeader
    blockhash = fromJust $ C.deserialiseFromRawBytes(C.proxyToAsType Proxy) bs
  in
    flip C.ChainPoint blockhash <$> [1 .. 3]

rewindTest :: Property
rewindTest = property $ do
  event0 <- forAll $ genEventAtChainPoint C.ChainPointAtGenesis
  event1 <- forAll $ genEventAtChainPoint (head chainpoints )
  event2 <- forAll $ genEventAtChainPoint (chainpoints !! 1)
  event3 <- forAll $ genEventAtChainPoint (chainpoints !! 2)
  indexer <- liftIO $ Utxo.open ":memory:" (Utxo.Depth 2)
             >>= liftIO . Storable.insertMany [event0, event1, event2, event3]
  cps' <- liftIO . resume $ indexer
  -- we should only see points up to depth: Genesis and the first insert
  sort cps' ===  [C.ChainPointAtGenesis, head chainpoints]


-- create TargetAddresses
-- We use TxOut to create a valid and relevant TargetAddress. This garnteed that the targetAddress is among the generated events.
mkTargetAddressFromTxOut
  :: [C.TxOut C.CtxTx CurrentEra]
  -> Maybe TargetAddresses
mkTargetAddressFromTxOut [C.TxOut addressInEra _ _ _]
    = nonEmpty
    . mapMaybe (addressAnyToShelley . Utxo.toAddr)
    $ [addressInEra]
mkTargetAddressFromTxOut _ = Nothing

addressAnyToShelley
  :: C.AddressAny
  -> Maybe (C.Address C.ShelleyAddr)
addressAnyToShelley  (C.AddressShelley a) = Just a
addressAnyToShelley  _                    = Nothing

getConn :: Storable.State Utxo.UtxoHandle -> SQL.Connection
getConn  s =
  let
    (Utxo.UtxoHandle c _)  = s ^. Storable.handle
  in c
