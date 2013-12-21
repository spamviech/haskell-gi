{-# LANGUAGE ScopedTypeVariables #-}
module GI.Utils.BasicTypes
    ( GType

    , gtypeString
    , gtypePointer
    , gtypeInt32
    , gtypeUInt32
    , gtypeInt64
    , gtypeUInt64
    , gtypeFloat
    , gtypeDouble
    , gtypeBoolean
    , gtypeStrv
    , gtypeBoxed
    , gtypeObject

    , GArray(..)
    , GPtrArray(..)
    , GByteArray(..)
    , GHashTable(..)
    , GList(..)
    , packGList
    , unpackGList
    , g_list_free
    , GSList(..)
    , packGSList
    , unpackGSList
    , g_slist_free
    , packGArray
    , unpackGArray
    , unrefGArray
    , packGPtrArray
    , unpackGPtrArray
    , unrefPtrArray
    , packGByteArray
    , unpackGByteArray
    , unrefGByteArray
    , packByteString
    , packZeroTerminatedByteString
    , unpackByteStringWithLength
    , unpackZeroTerminatedByteString
    , packFileNameArray
    , packZeroTerminatedFileNameArray
    , unpackZeroTerminatedFileNameArray
    , unpackFileNameArrayWithLength
    , packUTF8CArray
    , packZeroTerminatedUTF8CArray
    , unpackUTF8CArrayWithLength
    , unpackZeroTerminatedUTF8CArray
    , packStorableArray
    , packZeroTerminatedStorableArray
    , unpackStorableArrayWithLength
    , unpackZeroTerminatedStorableArray
    , packMapStorableArray
    , packMapZeroTerminatedStorableArray
    , unpackMapStorableArrayWithLength
    , unpackMapZeroTerminatedStorableArray
    , packPtrArray
    , packZeroTerminatedPtrArray
    , unpackPtrArrayWithLength
    , unpackZeroTerminatedPtrArray
    , packBlockArray
    , unpackBlockArrayWithLength

    , byteStringToCString

    , mapZeroTerminatedCArray
    , mapCArrayWithLength
    , mapGArray
    , mapPtrArray
    , mapGList
    , mapGSList
    ) where

import Foreign
import Foreign.C.Types
import Foreign.C.String
import Control.Monad (foldM)
import Control.Applicative ((<$>), (<*>))
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Internal as BI

import GI.Utils.Utils (memcpy)

#include <glib-object.h>

#if !defined(GLIB_VERSION_2_36)
#literal g_type_init();
#endif

type GType = #type GType

gtypeString :: GType
gtypeString = #const G_TYPE_STRING

gtypePointer :: GType
gtypePointer = #const G_TYPE_POINTER

gtypeInt32 :: GType
gtypeInt32 = #const G_TYPE_INT

gtypeUInt32 :: GType
gtypeUInt32 = #const G_TYPE_UINT

gtypeInt64 :: GType
gtypeInt64 = #const G_TYPE_INT64

gtypeUInt64 :: GType
gtypeUInt64 = #const G_TYPE_UINT64

gtypeFloat :: GType
gtypeFloat = #const G_TYPE_FLOAT

gtypeDouble :: GType
gtypeDouble = #const G_TYPE_DOUBLE

gtypeBoolean :: GType
gtypeBoolean = #const G_TYPE_BOOLEAN

gtypeStrv :: GType
gtypeStrv = #const G_TYPE_STRV

gtypeBoxed :: GType
gtypeBoxed = #const G_TYPE_BOXED

gtypeObject :: GType
gtypeObject = #const G_TYPE_OBJECT

data GArray a = GArray (Ptr (GArray a))
data GPtrArray a = GPtrArray (Ptr (GPtrArray a))
data GByteArray = GByteArray (Ptr GByteArray)
data GHashTable a b = GHashTable (Ptr (GHashTable a b))
data GList a = GList (Ptr (GList a))
data GSList a = GSList (Ptr (GSList a))

foreign import ccall unsafe "g_list_prepend" g_list_prepend ::
    Ptr (GList (Ptr a)) -> Ptr a -> IO (Ptr (GList (Ptr a)))
foreign import ccall unsafe "g_list_free" g_list_free ::
    Ptr (GList a) -> IO ()

-- Given a Haskell list of items, construct a GList with those values.
packGList   :: [Ptr a] -> IO (Ptr (GList (Ptr a)))
packGList l = foldM g_list_prepend nullPtr $ reverse l

-- Given a GSList construct the corresponding Haskell list.
unpackGList   :: Ptr (GList (Ptr a)) -> IO [Ptr a]
unpackGList gsl
    | gsl == nullPtr = return []
    | otherwise =
        do x <- peek (castPtr gsl)
           next <- peek (gsl `plusPtr` sizeOf x)
           xs <- unpackGList next
           return $ x : xs

-- Same thing for singly linked lists

foreign import ccall unsafe "g_slist_prepend" g_slist_prepend ::
    Ptr (GSList (Ptr a)) -> Ptr a -> IO (Ptr (GSList (Ptr a)))
foreign import ccall unsafe "g_slist_free" g_slist_free ::
    Ptr (GSList a) -> IO ()

-- Given a Haskell list of items, construct a GSList with those values.
packGSList   :: [Ptr a] -> IO (Ptr (GSList (Ptr a)))
packGSList l = foldM g_slist_prepend nullPtr $ reverse l

-- Given a GSList construct the corresponding Haskell list.
unpackGSList   :: Ptr (GSList (Ptr a)) -> IO [Ptr a]
unpackGSList gsl = unpackGList (castPtr gsl)

foreign import ccall unsafe "g_array_new" g_array_new ::
   CInt -> CInt -> CUInt -> IO (Ptr (GArray ()))
foreign import ccall unsafe "g_array_set_size" g_array_set_size ::
    Ptr (GArray ()) -> CUInt -> IO (Ptr (GArray ()))
foreign import ccall unsafe "g_array_unref" unrefGArray ::
   Ptr (GArray a) -> IO ()

packGArray :: forall a. Storable a => [a] -> IO (Ptr (GArray a))
packGArray elems = do
  let elemsize = sizeOf (elems!!0)
  array <- g_array_new 0 0 (fromIntegral elemsize)
  _ <- g_array_set_size array (fromIntegral $ length elems)
  dataPtr <- peek (castPtr array :: Ptr (Ptr a))
  fill dataPtr elems
  return $ castPtr array
  where
    fill            :: Ptr a -> [a] -> IO ()
    fill _ []       = return ()
    fill ptr (x:xs) =
        do poke ptr x
           fill (ptr `plusPtr` (sizeOf x)) xs

unpackGArray :: forall a. Storable a => Ptr (GArray a) -> IO [a]
unpackGArray array = do
  dataPtr <- peek (castPtr array :: Ptr (Ptr a))
  nitems <- peek (array `plusPtr` sizeOf dataPtr)
  go dataPtr nitems
    where go :: Ptr a -> Int -> IO [a]
          go _ 0 = return []
          go ptr n = do
            x <- peek ptr
            (x:) <$> go (ptr `plusPtr` sizeOf x) (n-1)

foreign import ccall unsafe "g_ptr_array_new" g_ptr_array_new ::
    IO (Ptr (GPtrArray ()))
foreign import ccall unsafe "g_ptr_array_set_size" g_ptr_array_set_size ::
    Ptr (GPtrArray ()) -> CUInt -> IO (Ptr (GPtrArray ()))
foreign import ccall unsafe "g_ptr_array_unref" unrefPtrArray ::
   Ptr (GPtrArray a) -> IO ()

packGPtrArray :: [Ptr a] -> IO (Ptr (GPtrArray (Ptr a)))
packGPtrArray elems = do
  array <- g_ptr_array_new
  _ <- g_ptr_array_set_size array (fromIntegral $ length elems)
  dataPtr <- peek (castPtr array :: Ptr (Ptr (Ptr a)))
  fill dataPtr elems
  return $ castPtr array
  where
    fill            :: Ptr (Ptr a) -> [Ptr a] -> IO ()
    fill _ []       = return ()
    fill ptr (x:xs) =
        do poke ptr x
           fill (ptr `plusPtr` (sizeOf x)) xs

unpackGPtrArray :: Ptr (GPtrArray (Ptr a)) -> IO [Ptr a]
unpackGPtrArray array = do
  dataPtr <- peek (castPtr array :: Ptr (Ptr (Ptr a)))
  nitems <- peek (array `plusPtr` sizeOf dataPtr)
  go dataPtr nitems
    where go :: Ptr (Ptr a) -> Int -> IO [Ptr a]
          go _ 0 = return []
          go ptr n = do
            x <- peek ptr
            (x:) <$> go (ptr `plusPtr` sizeOf x) (n-1)

foreign import ccall unsafe "g_byte_array_new" g_byte_array_new ::
    IO (Ptr GByteArray)
foreign import ccall unsafe "g_byte_array_append" g_byte_array_append ::
    Ptr GByteArray -> Ptr a -> CUInt -> IO (Ptr GByteArray)
foreign import ccall unsafe "g_byte_array_unref" unrefGByteArray ::
   Ptr GByteArray -> IO ()

packGByteArray :: ByteString -> IO (Ptr GByteArray)
packGByteArray bs = do
  array <- g_byte_array_new
  let (ptr, offset, length) = BI.toForeignPtr bs
  _ <- withForeignPtr ptr $ \dataPtr ->
                    g_byte_array_append array (dataPtr `plusPtr` offset)
                                        (fromIntegral length)
  return array

unpackGByteArray :: Ptr GByteArray -> IO ByteString
unpackGByteArray array = do
  dataPtr <- peek (castPtr array :: Ptr (Ptr CChar))
  length <- peek (array `plusPtr` (sizeOf dataPtr)) :: IO CUInt
  B.packCStringLen (dataPtr, fromIntegral length)

packByteString :: ByteString -> IO (Ptr Word8)
packByteString bs = do
  let (ptr, offset, length) = BI.toForeignPtr bs
  mem <- mallocBytes length
  withForeignPtr ptr $ \dataPtr ->
      memcpy mem (dataPtr `plusPtr` offset) (fromIntegral length)
  return mem

packZeroTerminatedByteString :: ByteString -> IO (Ptr Word8)
packZeroTerminatedByteString bs = do
  let (ptr, offset, length) = BI.toForeignPtr bs
  mem <- mallocBytes (length+1)
  withForeignPtr ptr $ \dataPtr ->
      memcpy mem (dataPtr `plusPtr` offset) (fromIntegral length)
  poke (mem `plusPtr` (offset+length)) (0 :: Word8)
  return mem

unpackByteStringWithLength :: Integral a => a -> Ptr Word8 -> IO ByteString
unpackByteStringWithLength length ptr =
  B.packCStringLen (castPtr ptr, fromIntegral length)

unpackZeroTerminatedByteString :: Ptr Word8 -> IO ByteString
unpackZeroTerminatedByteString ptr =
  B.packCString (castPtr ptr)

packStorableArray :: Storable a => [a] -> IO (Ptr a)
packStorableArray = packMapStorableArray id

packZeroTerminatedStorableArray :: (Num a, Storable a) => [a] -> IO (Ptr a)
packZeroTerminatedStorableArray = packMapZeroTerminatedStorableArray id

unpackStorableArrayWithLength :: (Integral a, Storable b) =>
                                 a -> Ptr b -> IO [b]
unpackStorableArrayWithLength = unpackMapStorableArrayWithLength id

unpackZeroTerminatedStorableArray :: (Eq a, Num a, Storable a) =>
                                     Ptr a -> IO [a]
unpackZeroTerminatedStorableArray = unpackMapZeroTerminatedStorableArray id

packMapStorableArray :: forall a b. Storable b => (a -> b) -> [a] -> IO (Ptr b)
packMapStorableArray fn items = do
  let nitems = length items
  mem <- mallocBytes $ (sizeOf (undefined::b)) * nitems
  fill mem (map fn items)
  return mem
  where fill            :: Ptr b -> [b] -> IO ()
        fill _ []       = return ()
        fill ptr (x:xs) = do
          poke ptr x
          fill (ptr `plusPtr` sizeOf x) xs

packMapZeroTerminatedStorableArray :: forall a b. (Num b, Storable b) =>
                                      (a -> b) -> [a] -> IO (Ptr b)
packMapZeroTerminatedStorableArray fn items = do
  let nitems = length items
  mem <- mallocBytes $ (sizeOf (undefined::b)) * (nitems+1)
  fill mem (map fn items)
  return mem
  where fill            :: Ptr b -> [b] -> IO ()
        fill ptr []     = poke ptr 0
        fill ptr (x:xs) = do
          poke ptr x
          fill (ptr `plusPtr` sizeOf x) xs

unpackMapStorableArrayWithLength :: forall a b c. (Integral a, Storable b) =>
                                    (b -> c) -> a -> Ptr b -> IO [c]
unpackMapStorableArrayWithLength fn n ptr = map fn <$> go (fromIntegral n) ptr
    where go :: Int -> Ptr b -> IO [b]
          go 0 _ = return []
          go n ptr = do
            x <- peek ptr
            (x:) <$> go (n-1) (ptr `plusPtr` sizeOf x)

unpackMapZeroTerminatedStorableArray :: forall a b. (Eq a, Num a, Storable a) =>
                                        (a -> b) -> Ptr a -> IO [b]
unpackMapZeroTerminatedStorableArray fn ptr = map fn <$> go ptr
    where go :: Ptr a -> IO [a]
          go ptr = do
            x <- peek ptr
            if x == 0
            then return []
            else (x:) <$> go (ptr `plusPtr` sizeOf x)

packUTF8CArray :: [String] -> IO (Ptr CString)
packUTF8CArray items = do
  let nitems = length items
  mem <- mallocBytes $ nitems * (sizeOf (nullPtr :: CString))
  fill mem items
  return mem
    where fill            :: Ptr CString -> [String] -> IO ()
          fill _ []       = return ()
          fill ptr (x:xs) =
              do cstring <- newCString x
                 poke ptr cstring
                 fill (ptr `plusPtr` sizeOf cstring) xs

packZeroTerminatedUTF8CArray :: [String] -> IO (Ptr CString)
packZeroTerminatedUTF8CArray items = do
    let nitems = length items
    mem <- mallocBytes $ (sizeOf (nullPtr :: CString)) * (nitems+1)
    fill mem items
    return mem
    where fill :: Ptr CString -> [String] -> IO ()
          fill ptr [] = poke ptr nullPtr
          fill ptr (x:xs) = do cstring <- newCString x
                               poke ptr cstring
                               fill (ptr `plusPtr` sizeOf cstring) xs

unpackZeroTerminatedUTF8CArray :: Ptr CString -> IO [String]
unpackZeroTerminatedUTF8CArray listPtr = go listPtr
    where go :: Ptr CString -> IO [String]
          go ptr = do
            cstring <- peek ptr
            if cstring == nullPtr
               then return []
               else (:) <$> peekCString cstring
                        <*> go (ptr `plusPtr` sizeOf cstring)

unpackUTF8CArrayWithLength :: Integral a => a -> Ptr CString -> IO [String]
unpackUTF8CArrayWithLength n ptr = go (fromIntegral n) ptr
    where go       :: Int -> Ptr CString -> IO [String]
          go 0 _   = return []
          go n ptr = do
            cstring <- peek ptr
            (:) <$> peekCString cstring
                    <*> go (n-1) (ptr `plusPtr` sizeOf cstring)

packFileNameArray :: [ByteString] -> IO (Ptr CString)
packFileNameArray items = do
  let nitems = length items
  mem <- mallocBytes $ nitems * (sizeOf (nullPtr :: CString))
  fill mem items
  return mem
    where fill            :: Ptr CString -> [ByteString] -> IO ()
          fill _ []       = return ()
          fill ptr (x:xs) =
              do cstring <- byteStringToCString x
                 poke ptr cstring
                 fill (ptr `plusPtr` sizeOf cstring) xs

packZeroTerminatedFileNameArray :: [ByteString] -> IO (Ptr CString)
packZeroTerminatedFileNameArray items = do
    let nitems = length items
    mem <- mallocBytes $ (sizeOf (nullPtr :: CString)) * (nitems+1)
    fill mem items
    return mem
    where fill :: Ptr CString -> [ByteString] -> IO ()
          fill ptr [] = poke ptr nullPtr
          fill ptr (x:xs) = do cstring <- byteStringToCString x
                               poke ptr cstring
                               fill (ptr `plusPtr` sizeOf cstring) xs

unpackZeroTerminatedFileNameArray :: Ptr CString -> IO [ByteString]
unpackZeroTerminatedFileNameArray listPtr = go listPtr
    where go :: Ptr CString -> IO [ByteString]
          go ptr = do
            cstring <- peek ptr
            if cstring == nullPtr
               then return []
               else (:) <$> B.packCString cstring
                        <*> go (ptr `plusPtr` sizeOf cstring)

unpackFileNameArrayWithLength :: Integral a =>
                                 a -> Ptr CString -> IO [ByteString]
unpackFileNameArrayWithLength n ptr = go (fromIntegral n) ptr
    where go       :: Int -> Ptr CString -> IO [ByteString]
          go 0 _   = return []
          go n ptr = do
            cstring <- peek ptr
            (:) <$> B.packCString cstring
                    <*> go (n-1) (ptr `plusPtr` sizeOf cstring)

byteStringToCString :: ByteString -> IO CString
byteStringToCString bs = castPtr <$> packZeroTerminatedByteString bs

packPtrArray :: [Ptr a] -> IO (Ptr (Ptr a))
packPtrArray items = do
  let nitems = length items
  mem <- mallocBytes $ (sizeOf (nullPtr :: Ptr a)) * nitems
  fill mem items
  return mem
  where fill :: Ptr (Ptr a) -> [Ptr a] -> IO ()
        fill _ [] = return ()
        fill ptr (x:xs) = do poke ptr x
                             fill (ptr `plusPtr` sizeOf x) xs

packZeroTerminatedPtrArray :: [Ptr a] -> IO (Ptr (Ptr a))
packZeroTerminatedPtrArray items = do
  let nitems = length items
  mem <- mallocBytes $ (sizeOf (nullPtr :: Ptr a)) * (nitems+1)
  fill mem items
  return mem
  where fill            :: Ptr (Ptr a) -> [Ptr a] -> IO ()
        fill ptr []     = poke ptr nullPtr
        fill ptr (x:xs) = do poke ptr x
                             fill (ptr `plusPtr` sizeOf x) xs

unpackPtrArrayWithLength :: Integral a => a -> Ptr (Ptr b) -> IO [Ptr b]
unpackPtrArrayWithLength n ptr = go (fromIntegral n) ptr
    where go       :: Int -> Ptr (Ptr a) -> IO [Ptr a]
          go 0 _   = return []
          go n ptr = (:) <$> peek ptr
                     <*> go (n-1) (ptr `plusPtr` sizeOf (nullPtr :: Ptr a))

unpackZeroTerminatedPtrArray :: Ptr (Ptr a) -> IO [Ptr a]
unpackZeroTerminatedPtrArray ptr = go ptr
    where go :: Ptr (Ptr a) -> IO [Ptr a]
          go ptr = do
            p <- peek ptr
            if p == nullPtr
            then return []
            else (p:) <$> go (ptr `plusPtr` sizeOf p)

mapZeroTerminatedCArray :: (Ptr a -> IO b) -> Ptr (Ptr a) -> IO ()
mapZeroTerminatedCArray f dataPtr
    | (dataPtr == nullPtr) = return ()
    | otherwise =
        do ptr <- peek dataPtr
           if ptr == nullPtr
           then return ()
           else do
             _ <- f ptr
             mapZeroTerminatedCArray f (dataPtr `plusPtr` sizeOf ptr)

packBlockArray :: Int -> [Ptr a] -> IO (Ptr a)
packBlockArray size items = do
  let nitems = length items
  mem <- mallocBytes $ size * nitems
  fill mem items
  return mem
  where fill :: Ptr a -> [Ptr a] -> IO ()
        fill _ [] = return ()
        fill ptr (x:xs) = do memcpy ptr x size
                             fill (ptr `plusPtr` size) xs

unpackBlockArrayWithLength :: (Integral a) => Int -> a -> Ptr b -> IO [Ptr b]
unpackBlockArrayWithLength size n ptr = go size (fromIntegral n) ptr
    where go       :: Int -> Int -> Ptr b -> IO [Ptr b]
          go _ 0 _   = return []
          go size n ptr = do
            buf <- mallocBytes size
            memcpy buf ptr size
            (buf :) <$> go size (n-1) (ptr `plusPtr` size)

mapCArrayWithLength :: (Storable a, Integral b) =>
                       b -> (a -> IO c) -> Ptr a -> IO ()
mapCArrayWithLength n f dataPtr
    | (dataPtr == nullPtr) = return ()
    | (n <= 0) = return ()
    | otherwise =
        do ptr <- peek dataPtr
           _ <- f ptr
           mapCArrayWithLength (n-1) f (dataPtr `plusPtr` sizeOf ptr)

mapGArray :: forall a b. Storable a => (a -> IO b) -> Ptr (GArray a) -> IO ()
mapGArray f array
    | (array == nullPtr) = return ()
    | otherwise =
        do dataPtr <- peek (castPtr array :: Ptr (Ptr a))
           nitems <- peek (array `plusPtr` sizeOf dataPtr)
           go dataPtr nitems
               where go :: Ptr a -> Int -> IO ()
                     go _ 0 = return ()
                     go ptr n = do
                       x <- peek ptr
                       _ <- f x
                       go (ptr `plusPtr` sizeOf x) (n-1)

mapPtrArray :: (Ptr a -> IO b) -> Ptr (GPtrArray (Ptr a)) -> IO ()
mapPtrArray f array = mapGArray f (castPtr array)

mapGList :: (Ptr a -> IO b) -> Ptr (GList (Ptr a)) -> IO ()
mapGList f glist
    | (glist == nullPtr) = return ()
    | otherwise =
        do ptr <- peek (castPtr glist)
           next <- peek (glist `plusPtr` sizeOf ptr)
           _ <- f ptr
           mapGList f next

mapGSList :: (Ptr a -> IO b) -> Ptr (GSList (Ptr a)) -> IO ()
mapGSList f gslist = mapGList f (castPtr gslist)