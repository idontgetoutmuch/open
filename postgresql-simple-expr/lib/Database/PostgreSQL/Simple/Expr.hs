{-# LANGUAGE TypeFamilies, GeneralizedNewtypeDeriving, DeriveGeneric, DefaultSignatures,
             PolyKinds, TypeOperators, ScopedTypeVariables, FlexibleContexts,
             FlexibleInstances, UndecidableInstances,
             OverloadedStrings, TypeApplications, StandaloneDeriving #-}

module Database.PostgreSQL.Simple.Expr where

import Database.PostgreSQL.Simple
import Database.PostgreSQL.Simple.FromField
import Database.PostgreSQL.Simple.FromRow
import Database.PostgreSQL.Simple.ToField
import Database.PostgreSQL.Simple.ToRow

import GHC.Generics
import Data.Proxy
import qualified GHC.Int
import Data.String
import Data.List (intercalate, intersperse)
import Data.Monoid ((<>), mconcat)
import Data.Maybe (listToMaybe)
import Data.Aeson
import Data.Text (Text, pack)
import Control.Monad.Reader
import Control.Exception.Safe
import Fake

class MonadIO m => MonadConnection m where
  getConnection :: m Connection

instance MonadIO m => MonadConnection (ReaderT Connection m) where
  getConnection = ask

withConnection :: MonadConnection m => (Connection-> IO a) -> m a
withConnection f = getConnection >>= \c -> liftIO $ f c

class HasFieldNames a where
  getFieldNames :: Proxy a -> [String]

  default getFieldNames :: (Selectors (Rep a)) => Proxy a -> [String]
  getFieldNames proxy = selectors proxy

queryC  :: (MonadConnection m,ToRow q, FromRow r) => Query -> q -> m [r]
queryC fullq args = withConnection $ \conn -> query conn fullq args

executeC  :: (MonadConnection m,ToRow q) => Query -> q -> m GHC.Int.Int64
executeC fullq args = withConnection $ \conn -> execute conn fullq args


selectFrom :: forall r q m. (ToRow q, FromRow r, HasFieldNames r,MonadConnection m) => Query -> q -> m [r]
selectFrom q1 args = do
  let fullq = "select " <> (fromString $ intercalate "," $ getFieldNames $ (Proxy :: Proxy r) ) <> " from " <> q1
  queryC fullq args

class HasFieldNames a => HasTable a where
  tableName :: Proxy a -> String

selectWhere :: forall r q m. (ToRow q, FromRow r, HasTable r,MonadConnection m)
            =>  Query -> q -> m [r]
selectWhere q1 args = do
  let fullq = "select " <> (fromString $ intercalate "," $ getFieldNames $ (Proxy :: Proxy r) )
                        <> " from " <> fromString (tableName (Proxy :: Proxy r))
                        <> " where " <> q1
  queryC fullq args

countFrom :: (ToRow q,MonadConnection m) => Query -> q -> m Int
countFrom q1 args = do
  let fullq = "select count(*) from "<>q1
      unOnly (Only x) = x
  n :: [Only Int] <- queryC fullq args
  return $ sum $ map unOnly n

withTransactionC :: (MonadMask m, MonadConnection m) => m a -> m a
withTransactionC act =
  mask $ \restore -> do
    withConnection begin
    r <- restore act `onException` (withConnection rollback)
    withConnection commit
    return r

--insert all fields
insertAll :: forall r m. (ToRow r, HasTable r,MonadConnection m) =>  r -> m ()
insertAll  val = do
  let fnms = getFieldNames $ (Proxy :: Proxy r)
  _ <- executeC ("INSERT INTO " <> fromString (tableName (Proxy :: Proxy r)) <> " (" <>
                     (fromString $ intercalate "," fnms ) <>
                     ") VALUES (" <>
                     (fromString $ intercalate "," $ map (const "?") fnms) <> ")")
             val
  return ()

  --insert all fields
insertAllOrDoNothing :: forall r m. (ToRow r, HasTable r,MonadConnection m) =>  r -> m ()
insertAllOrDoNothing   val = do
  let fnms = getFieldNames $ (Proxy :: Proxy r)
  _ <- executeC ("INSERT INTO " <> fromString (tableName (Proxy :: Proxy r)) <> " (" <>
                     (fromString $ intercalate "," fnms ) <>
                     ") VALUES (" <>
                     (fromString $ intercalate "," $ map (const "?") fnms) <> ") ON CONFLICT DO NOTHING")
             val
  return ()


class KeyField a where
   toFields :: a -> [Action]
   toText :: a -> Text
   autoIncrementing :: Proxy a -> Bool
   fromFields :: RowParser a

   default toFields :: ToField a => a -> [Action]
   toFields = (:[]) . toField
   default toText :: Show a => a -> Text
   toText = pack . show
   default fromFields :: FromField a => RowParser a
   fromFields = field

   autoIncrementing _ = False

newtype ParseKey a = ParseKey { unParseKey :: a } deriving (Show, Generic)

instance KeyField a => FromRow (ParseKey a) where
  fromRow = ParseKey <$> fromFields

instance KeyField a => ToRow (ParseKey a) where
  toRow (ParseKey k) = toFields k

instance {-# OVERLAPS #-} (ToRow a, FromRow a, Show a) => KeyField a where
  toFields = toRow
  fromFields = fromRow

instance KeyField Int
instance KeyField Text
instance KeyField String

class HasTable a => HasKey a where
  type Key a
  getKey :: a -> Key a
  getKeyFieldNames :: Proxy a -> [String]

data OnConflict = OnConflictDefault | OnConflictDoNothing
  deriving (Show, Eq)

onConflictQ :: OnConflict -> Query
onConflictQ OnConflictDefault = mempty
onConflictQ OnConflictDoNothing = "ON CONFLICT DO NOTHING"

-- Internal function to handle both `insert` and `insertOrDoNothing`
insert' :: forall a m . (HasKey a, KeyField (Key a), ToRow a, MonadConnection m)
        => OnConflict -> a -> m (Key a)
insert' onConflict val = do
  if autoIncrementing (undefined :: Proxy (Key a))
     then ginsertSerial onConflict val
     else do insertAll  val
             return $ getKey val

ginsertSerial :: forall a m .
                 (HasKey a, KeyField (Key a), ToRow a, MonadConnection m)
              => OnConflict -> a -> m (Key a)
ginsertSerial onConflict val = do
           let keyNames = map fromString $ getKeyFieldNames (Proxy :: Proxy a)
               notInKeyNames = not . (`elem` keyNames)
               tblName = fromString $ tableName (Proxy :: Proxy a)
               fldNms = map fromString $ getFieldNames (Proxy :: Proxy a)
               fldNmsNoKey = filter notInKeyNames fldNms
               qmarks = mconcat $ intersperse "," $ map (const "?") fldNmsNoKey
               fields = mconcat $ intersperse "," $ fldNmsNoKey
               qArgs = map snd $ filter (notInKeyNames . fst) $ zip fldNms $ toRow val
               qKeySet = mconcat $ intersperse "," keyNames
               q = "insert into "<>tblName<>"("<>fields<>") values ("<>qmarks<>") "
                 <> onConflictQ onConflict <> " returning "<>qKeySet
           res <- queryC q qArgs
           case res of
             [] -> fail $ "no key returned from "++show tblName
             ParseKey ks:_ -> return ks

insert :: forall a m . (HasKey a, KeyField (Key a), ToRow a, MonadConnection m) => a -> m (Key a)
insert = insert' OnConflictDefault

insertOrDoNothing :: forall a m . (HasKey a, KeyField (Key a), ToRow a, MonadConnection m) =>  a -> m (Key a)
insertOrDoNothing = insert' OnConflictDoNothing

update
  :: forall a m . (HasKey a, KeyField (Key a), ToRow a,MonadConnection m)
  =>  a -> m ()
update  val = do
  let keyNames = map fromString $ getKeyFieldNames (Proxy :: Proxy a)
      notInKeyNames = not . (`elem` keyNames)
      kval = getKey val
      tblName = fromString $ tableName (Proxy :: Proxy a)
      fldNms = map fromString $ getFieldNames (Proxy :: Proxy a)
      fldNmsNoKey = filter notInKeyNames fldNms
      qArgs = map snd $ filter (notInKeyNames . fst) $ zip fldNms $ toRow val
      fieldQ = mconcat $ intersperse ", " $ map (\f-> f <>" = ?") fldNmsNoKey
      (keyQ, keyA) = keyRestrict (Proxy @a) kval
      q = "update "<>tblName<>" set "<>fieldQ<>" where "<>keyQ
  _ <- executeC q $ qArgs ++ keyA
  return ()

delete
  :: forall a  m. (HasKey a, KeyField (Key a), MonadConnection m)
  =>  a -> m ()
delete  x = do
  let tblName = fromString $ tableName (Proxy :: Proxy a)
      kval = getKey x
      (keyQ, keyA) = keyRestrict (Proxy @a) kval
      q = "delete from "<> tblName<>" where "<> keyQ
  _ <- executeC q keyA
  return ()

deleteByKey
  :: forall a m . (HasKey a, KeyField (Key a),MonadConnection m)
  =>  Proxy a -> Key a -> m ()
deleteByKey  px k = do
  let tblName = fromString $ tableName px
      (keyQ, keyA) = keyRestrict (Proxy @a) k
      q = "delete from "<> tblName<>" where "<>keyQ
  _ <- executeC q keyA
  return ()

conjunction :: [Query] -> Query
conjunction [] = "true"
conjunction (q1:[]) = q1
--conjunction (q1:q2:[]) = "("<>q1<>") and ("<>q2<>")" --needed?
conjunction (q1:qs) = "("<>q1<>") and "<>conjunction qs

keyRestrict :: (HasKey a, KeyField (Key a)) => Proxy a -> Key a -> (Query, [Action])
keyRestrict px key
  = let nms = getKeyFieldNames px
        q1 nm = fromString nm <> " = ? "
        q = conjunction $ map q1 nms
    in (q, toFields key)

-- |Fetch a row by its primary key

getByKey :: forall a m . (HasKey a, KeyField (Key a), FromRow a,MonadConnection m) =>  Key a -> m (Maybe a)
getByKey  key = do
  let (q, as) = keyRestrict (Proxy :: Proxy a) key
  ress <- selectWhere  q as
  return $ listToMaybe ress

newtype Serial a = Serial { unSerial :: a }
  deriving (Num, Ord, Show, Read, Eq, Generic, ToField, FromField)

-- `serial` bounds in postgresql
instance Num a => Fake (Serial a) where
  fake = Serial . fromIntegral <$> fakeInt 0 2147483647

instance (ToField a, FromField a, KeyField a) => KeyField (Serial a) where
  toFields (Serial x) = [toField x]
  toText (Serial x) = toText x
  autoIncrementing _ = True

instance ToJSON a => ToJSON (Serial a) where
  toJSON (Serial x) = toJSON x
instance FromJSON a => FromJSON (Serial a) where
  parseJSON mx = Serial <$> parseJSON mx

------------------------------------------------------------
newtype Foreign parent = Foreign { unForeign :: Key parent }
  deriving Generic

deriving instance (Read (Key t)) => Read (Foreign t)
deriving instance (Show (Key t)) => Show (Foreign t)
deriving instance (Eq (Key t)) => Eq (Foreign t)
deriving instance (Ord (Key t)) => Ord (Foreign t)
deriving instance (ToField (Key t)) => ToField (Foreign t)
deriving instance (FromField (Key t)) => FromField (Foreign t)
deriving instance (ToRow (Key t)) => ToRow (Foreign t)
-- deriving instance (FromRow (Key t)) => FromRow (Foreign t)

instance (Fake (Key t)) => Fake (Foreign t) where
  fake = Foreign <$> fake

------------------------------------------------------------

-- https://hackage.haskell.org/package/hpack-0.15.0/src/src/Hpack/GenericsUtil.hs
-- Copyright (c) 2014-2016 Simon Hengel <sol@typeful.net>

selectors :: (Selectors (Rep a)) => Proxy a -> [String]
selectors = f
  where
    f :: forall a. (Selectors (Rep a)) => Proxy a -> [String]
    f _ = selNames (Proxy :: Proxy (Rep a))


class Selectors a where
  selNames :: Proxy a -> [String]

instance Selectors f => Selectors (M1 D x f) where
  selNames _ = selNames (Proxy :: Proxy f)

instance Selectors f => Selectors (M1 C x f) where
  selNames _ = selNames (Proxy :: Proxy f)

instance Selector s => Selectors (M1 S s (K1 R t)) where
  selNames _ = [selName (undefined :: M1 S s (K1 R t) ())]

instance (Selectors a, Selectors b) => Selectors (a :*: b) where
  selNames _ = selNames (Proxy :: Proxy a) ++ selNames (Proxy :: Proxy b)

instance Selectors U1 where
  selNames _ = []
