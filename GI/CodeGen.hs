module GI.CodeGen
    ( genConstant
    , genFunction
    , genCode
    , genModule
    ) where

import Control.Monad (forM, forM_, when)
import Control.Monad.Writer (tell)
import Data.List (intercalate)
import Data.Tuple (swap)
import Data.Maybe (fromJust, isJust)
import qualified Data.Map as M

import GI.API
import GI.Callable (genCallable)
import GI.Conversions
import GI.Code
import GI.GObject
import GI.Properties
import GI.Signal (genSignal)
import GI.SymbolNaming
import GI.Type
import GI.Util
import GI.Value
import GI.Internal.ArgInfo
import GI.Internal.FunctionInfo

valueStr VVoid         = "()"
valueStr (VBoolean x)  = show x
valueStr (VInt8 x)     = show x
valueStr (VUInt8 x)    = show x
valueStr (VInt16 x)    = show x
valueStr (VUInt16 x)   = show x
valueStr (VInt32 x)    = show x
valueStr (VUInt32 x)   = show x
valueStr (VInt64 x)    = show x
valueStr (VUInt64 x)   = show x
valueStr (VFloat x)    = show x
valueStr (VDouble x)   = show x
valueStr (VGType x)    = show x
valueStr (VUTF8 x)     = show x
valueStr (VFileName x) = show x

genConstant :: Name -> Constant -> CodeGen ()
genConstant n@(Name _ name) (Constant value) = do
    name' <- literalName n
    ht <- haskellType $ valueType value
    line $ "-- constant " ++ name
    line $ name' ++ " :: " ++ show ht
    line $ name' ++ " = " ++ valueStr value

genFunction :: Name -> Function -> CodeGen ()
genFunction n (Function symbol callable flags) = do
  line $ "-- function " ++ symbol
  genCallable n symbol callable (FunctionThrows `elem` flags)

genBoxedObject :: Name -> String -> CodeGen ()
genBoxedObject n typeInit = do
  name' <- upperName n

  group $ do
    line $ "foreign import ccall unsafe \"" ++ typeInit ++ "\" c_" ++
            typeInit ++ " :: "
    indent $ line $ "IO GType"
  group $ do
       line $ "instance BoxedObject " ++ name' ++ " where"
       indent $ line $ "boxedType _ = c_" ++ typeInit

genStruct :: Name -> Struct -> CodeGen ()
genStruct n@(Name _ name) s = when (not $ isGTypeStruct s) $ do
      cfg <- config

      line $ "-- struct " ++ name
      name' <- upperName n

      line $ "data " ++ name' ++ " = " ++ name' ++ " (ForeignPtr " ++ name' ++ ")"

      if structIsBoxed s
      then do
        manageManagedPtr n
        genBoxedObject n $ fromJust (structTypeInit s)
      else manageUnManagedPtr n

    -- XXX: Generate code for fields.

    -- Methods
      forM_ (structMethods s) $ \(mn, f) ->
          do isFunction <- symbolFromFunction (fnSymbol f)
             when (not $ isFunction || fnSymbol f `elem` ignoredMethods cfg) $
                  genMethod n mn f

genEnum :: Name -> Enumeration -> CodeGen ()
genEnum n@(Name ns name) (Enumeration fields eDomain maybeTypeInit) = do
  line $ "-- enum " ++ name
  name' <- upperName n
  fields' <- forM fields $ \(fieldName, value) -> do
      n <- upperName $ Name ns (name ++ "_" ++ fieldName)
      return (n, value)
  group $ do
    line $ "data " ++ name' ++ " = "
    indent $ do
      case fields' of
        ((fieldName, _value):fs) -> do
          line $ "  " ++ fieldName
          forM_ fs $ \(n, _) -> line $ "| " ++ n
          line $ "deriving (Show, Eq)"
        _ -> return ()
  group $ do
    line $ "instance Enum " ++ name' ++ " where"
    indent $ forM_ fields' $ \(n, v) ->
      line $ "fromEnum " ++ n ++ " = " ++ show v
    let valueNames = M.toList . M.fromListWith (curry snd) $ map swap fields'
    blank
    indent $ forM_ valueNames $ \(v, n) ->
      line $ "toEnum " ++ show v ++ " = " ++ n

  when (isJust eDomain) $ genErrorDomain name' (fromJust eDomain)

  when (isJust maybeTypeInit) $ genBoxedObject n (fromJust maybeTypeInit)

genErrorDomain :: String -> String -> CodeGen ()
genErrorDomain name' domain = do
  group $ do
    line $ "instance GErrorClass " ++ name' ++ " where"
    indent $ line $
               "gerrorDomain _ = \"" ++ domain ++ "\""
  -- Generate type specific error handling (saves a bit of typing, and
  -- it's clearer to read).
  group $ do
    let catcher = "catch" ++ name'
    line $ catcher ++ " ::"
    indent $ do
            line $ "IO a ->"
            line $ "(" ++ name' ++ " -> GErrorMessage -> IO a) ->"
            line $ "IO a"
    line $ catcher ++ " = catchGErrorJustDomain"
  group $ do
    let handler = "handle" ++ name'
    line $ handler ++ " ::"
    indent $ do
            line $ "(" ++ name' ++ " -> GErrorMessage -> IO a) ->"
            line $ "IO a ->"
            line $ "IO a"
    line $ handler ++ " = handleGErrorJustDomain"

genFlags :: Name -> Flags -> CodeGen ()
genFlags n@(Name _ name) (Flags (Enumeration _fields _ _)) = do
  line $ "-- flags " ++ name
  name' <- upperName n
  -- XXX: Generate code for fields.
  -- XXX: We should generate code for converting to/from lists.
  line $ "type " ++ name' ++ " = Word"

genCallback :: Name -> Callback -> CodeGen ()
genCallback n _ = do
  name' <- upperName n
  line $ "-- callback " ++ name' ++ " "
  -- XXX
  --line $ "data " ++ name' ++ " = " ++ name' ++ " (Ptr (IO ()))"
  line $ "data " ++ name' ++ " = " ++ name' ++ " (Ptr " ++ name' ++ ")"

genUnion n u = do
  name' <- upperName n
  cfg <- config

  line $ "-- union " ++ name' ++ " "

  line $ "data " ++ name' ++ " = " ++ name' ++ " (ForeignPtr " ++ name' ++ ")"

  if unionIsBoxed u
  then do
    manageManagedPtr n
    genBoxedObject n $ fromJust (unionTypeInit u)
  else manageUnManagedPtr n

  -- XXX Fields

  -- Methods
  forM_ (unionMethods u) $ \(mn, f) ->
      do isFunction <- symbolFromFunction (fnSymbol f)
         when (not $ isFunction || fnSymbol f `elem` ignoredMethods cfg) $
              genMethod n mn f

-- Add the implicit object argument to methods of an object.
fixMethodArgs :: Name -> Callable -> Callable
fixMethodArgs cn c = c {  args = args' , returnType = returnType' }
    where
      -- Since we are prepending an argument we need to adjust the
      -- offset of the length arguments of CArrays.
      returnType' = fixCArrayLength $ returnType c
      args' = objArg : map fixLengthArg (args c)
      fixLengthArg :: Arg -> Arg
      fixLengthArg arg = arg { argType = fixCArrayLength (argType arg)}
      fixCArrayLength :: Type -> Type
      fixCArrayLength (TCArray zt fixed length t) =
          TCArray zt fixed (length+1) t
      fixCArrayLength t = t
      objArg = Arg {
                 argName = "_obj",
                 argType = TInterface (namespace cn) (name cn),
                 direction = DirectionIn,
                 mayBeNull = False,
                 scope = ScopeTypeInvalid,
                 transfer = TransferNothing }

-- For constructors we want to return the actual type of the object,
-- rather than a generic superclass (so Gtk.labelNew returns a
-- Gtk.Label, rather than a Gtk.Widget)
fixConstructorReturnType :: Bool -> Name -> Callable -> Callable
fixConstructorReturnType returnsGObject cn c = c { returnType = returnType' }
    where
      returnType' = if returnsGObject then
                        TInterface (namespace cn) (name cn)
                    else
                        returnType c

genMethod :: Name -> Name -> Function -> CodeGen ()
genMethod cn mn (Function {
                    fnSymbol = sym,
                    fnCallable = c,
                    fnFlags = fs }) = do
    name' <- upperName cn
    returnsGObject <- isGObject (returnType c)
    line $ "-- method " ++ name' ++ "::" ++ (name mn)
    line $ "-- flags : " ++ show fs
    let -- Mangle the name to namespace it to the class.
        mn' = mn { name = name cn ++ "_" ++ name mn }
    let c'  = if FunctionIsConstructor `elem` fs
              then fixConstructorReturnType returnsGObject cn c
              else c
        c'' = if FunctionIsMethod `elem` fs
              then fixMethodArgs cn c'
              else c'
    genCallable mn' sym c'' (FunctionThrows `elem` fs)

-- Since all GObjects are instances of their own class, ManagedPtr and
-- GObject, the method signatures can get a little cumbersome. The
-- construction below basically defines a constraint synonym, so the
-- resulting signatures are shorter. A perhaps nicer way of achieving
-- the same thing would be to use the ConstraintKinds extension, but
-- doing things in the current manner has the advantage that the
-- generated (goConstraint name') has directly kind "* -> Constraint",
-- which plays well with the way we are implementing polymorphic
-- lenses for GObject properties.
genUnifiedConstraint name' = do
  let unified = parenthesize (intercalate ", " $ [klass name' ++ " a",
                                                  "ManagedPtr a",
                                                  "GObject a"])
                ++ " => " ++ goConstraint name' ++ " a where {}"
  line $ "class " ++ unified
  line $ "instance " ++ unified

-- Instantiation mechanism, so we can convert different object types
-- descending from GObject into each other.
genGObjectType iT n = do
  name' <- upperName n
  let className = klass name'

  line $ "class " ++ className ++ " o"

  genUnifiedConstraint name'

  manageManagedPtr n

  group $ do
    line $ "instance " ++ className ++ " " ++ name'
    forM_ iT $ \ancestor -> do
          ancestor' <- upperName ancestor
          line $ "instance " ++ (klass ancestor') ++ " " ++ name'

-- Type casting with type checking
genGObjectCasts n o = do
  name' <- upperName n

  let cn_ = objTypeInit o

  group $ do
    line $ "foreign import ccall unsafe \"" ++ cn_ ++ "\""
    indent $ line $ "c_" ++ cn_ ++ " :: IO GType"

  group $ do
    line $ "instance GObject " ++ name' ++ " where"
    indent $ line $ "gobjectType _ = c_" ++ cn_

  group $ do
    line $ "castTo" ++ name' ++ " :: " ++
           "(ManagedPtr o, GObject o) => " ++
           "o -> IO " ++ name'
    line $ "castTo" ++ name' ++ " = castTo " ++ name' ++
           " \"" ++ name' ++ "\""

-- ManagedPtr implementation, for types with real memory management.
manageManagedPtr n = do
  name' <- upperName n
  group $ do
    line $ "instance ManagedPtr " ++ name' ++ " where"
    indent $ do
            line $ "unsafeManagedPtrGetPtr = (\\(" ++ name' ++
                     " x) -> castPtr $ unsafeForeignPtrToPtr x)"
            line $ "touchManagedPtr        = (\\(" ++ name' ++
                     " x) -> touchForeignPtr x)"

-- Some objects, such as APIObjects not descending from GObjects, or
-- structs/unions which are not boxed cannot be automatically memoery
-- managed. For the moment we just implement no-ops here.
manageUnManagedPtr n = do
  name' <- upperName n
  group $ do
    line $ "instance ManagedPtr " ++ name' ++ " where"
    indent $ do
            line $ "unsafeManagedPtrGetPtr = (\\(" ++ name' ++
                     " x) -> castPtr $ unsafeForeignPtrToPtr x)"
            line $ "touchManagedPtr      _ = return ()"

genObject n o = do
  name' <- upperName n

  line $ "-- object " ++ name' ++ " "

  let t = (\(Name ns' n') -> TInterface ns' n') n
  isGO <- isGObject t

  when (not isGO) $ line $ "-- XXX APIObject \"" ++ name' ++
           "\" does not descend from GObject."

  line $ "newtype " ++ name' ++ " = " ++ name' ++ " (ForeignPtr " ++ name' ++ ")"
  cfg <- config

  -- Instances and type conversions
  if isGO
  then genGObjectType (instanceTree (instances cfg) n) n
  else manageUnManagedPtr n

  -- Implemented interfaces
  let oIfs = objInterfaces o
  when ((not . null) oIfs) $ group $ forM_ oIfs $ \(Name ns n) -> do
    prefix <- qualify ns
    let ifClass = prefix ++ interfaceClassName n
    line $ "instance " ++ ifClass ++ " " ++ name'

  -- Type safe casting
  when isGO $ genGObjectCasts n o

  -- Properties
  when isGO $ genObjectProperties n o

  -- Methods
  forM_ (objMethods o) $ \(mn, f) -> do
    when (not $ fnSymbol f `elem` ignoredMethods cfg) $
         genMethod n mn f

  -- And finally signals
  forM_ (objSignals o) $ \(sn, s) -> genSignal sn s n o

genInterface n iface = do
  cfg <- config

  -- For each interface, we generate a class IFoo and a data structure
  -- Foo. We only really need a separate Foo so that we can return
  -- them from bound functions. In principle we might be able to do
  -- something more elegant with existential types.

  name' <- upperName n
  let cls = interfaceClassName name'
  line $ "-- interface " ++ name' ++ " "
  line $ "newtype " ++ name' ++ " = " ++ name' ++ " (ForeignPtr " ++ name' ++ ")"
  line $ "class " ++ cls ++ " a"

  isGO <- apiIsGObject n (APIInterface iface)
  if isGO
  then do
    genUnifiedConstraint name'
    manageManagedPtr n
  else manageUnManagedPtr n

  group $ do
    line $ "instance " ++ cls ++ " " ++ name'
    -- We are also instances of our prerequisites
    forM_ (ifPrerequisites iface) $ \pName@(Name ns n) -> do
      prefix <- qualify ns
      api <- findAPI (TInterface ns n)
      case api of
        Just (APIInterface _) ->
            line $ "instance " ++ prefix ++ interfaceClassName n ++ " " ++ name'
        Just (APIObject _) -> do
            line $ "instance " ++ prefix ++ klass n ++ " " ++ name'
            -- We are also instances of the parents of the object
            forM_ (instanceTree (instances cfg) pName) $ \ancestor -> do
                  ancestor' <- upperName ancestor
                  line $ "instance " ++ (klass ancestor') ++ " " ++ name'
        _ -> error $ "Prerequisite is neither an object or an interface!? : "
                       ++ ns ++ "." ++ n

  when isGO $ do
    let cn_ = case ifTypeInit iface of
                Just typeInit -> typeInit
                Nothing -> error $ "GObject derived interface without a type!"

    group $ do
      line $ "foreign import ccall unsafe \"" ++ cn_ ++ "\""
      indent $ line $ "c_" ++ cn_ ++ " :: IO GType"

    group $ do
      line $ "instance GObject " ++ name' ++ " where"
      indent $ line $ "gobjectType _ = c_" ++ cn_

  -- Properties
  when isGO $ genInterfaceProperties n iface

  -- Methods
  cfg <- config
  forM_ (ifMethods iface) $ \(mn, f) -> do
    isFunction <- symbolFromFunction (fnSymbol f)
    when (not $ isFunction || fnSymbol f `elem` ignoredMethods cfg) $
       genMethod n mn f

-- Some type libraries seem to include spurious interface/struct
-- methods, where a method Mod.Foo::func also appears as an ordinary
-- function in the list of APIs. If we find a matching function, we
-- don't generate the method.
--
-- It may be more expedient to keep a map of symbol -> function.
symbolFromFunction :: String -> CodeGen Bool
symbolFromFunction sym = do
  cfg <- config
  return $ any (hasSymbol sym . snd) $ M.toList $ input cfg
    where
      hasSymbol sym1 (APIFunction (Function { fnSymbol = sym2 })) = sym1 == sym2
      hasSymbol _ _ = False

genCode :: Name -> API -> CodeGen ()
genCode n (APIConst c) = genConstant n c
genCode n (APIFunction f) = genFunction n f
genCode n (APIEnum e) = genEnum n e
genCode n (APIFlags f) = genFlags n f
genCode n (APICallback c) = genCallback n c
genCode n (APIStruct s) = genStruct n s
genCode n (APIUnion u) = genUnion n u
genCode n (APIObject o) = genObject n o
genCode n (APIInterface i) = genInterface n i
genCode _ (APIBoxed _) = return ()

genModule :: String -> [(Name, API)] -> String -> CodeGen ()
genModule name apis modulePrefix = do
    cfg <- config

    line $ "-- Generated code."
    blank
    line $ "{-# LANGUAGE ForeignFunctionInterface, ConstraintKinds,"
    line $ "    TypeFamilies, MultiParamTypeClasses, KindSignatures,"
    line $ "    FlexibleInstances, UndecidableInstances #-}"
    blank
    let mp = (modulePrefix ++)
    -- XXX: Generate export list.
    line $ "module " ++ mp name ++ " where"
    blank
    -- String and IOError also appear in GLib.
    line $ "import Prelude hiding (String, IOError)"
    -- Error types come from GLib.
    when (name /= "GLib") $
         line $ "import " ++ mp "GLib (Error(..))"
    line $ "import Data.Char"
    line $ "import Data.Int"
    line $ "import Data.Word"
    line $ "import Data.Array (Array(..))"
    line $ "import qualified Data.ByteString.Char8 as B"
    line $ "import Data.ByteString.Char8 (ByteString)"
    line $ "import Foreign.Safe"
    line $ "import qualified Foreign.Safe as F"
    line $ "import Foreign.ForeignPtr.Unsafe"
    line $ "import Foreign.C"
    line $ "import Control.Applicative ((<$>))"
    line $ "import Control.Monad (when)"
    line $ "import Control.Exception (onException)"
    blank
    line $ "import " ++ mp "Utils.Attributes"
    line $ "import " ++ mp "Utils.BasicTypes"
    line $ "import " ++ mp "Utils.GError"
    line $ "import " ++ mp "Utils.ManagedPtr"
    line $ "import " ++ mp "Utils.Properties"
    line $ "import " ++ mp "Utils.Utils"
    blank
    line $ "import " ++ mp name ++ "Lenses"
    blank

    forM_ (imports cfg) $ \i -> do
      line $ "import qualified " ++ mp (ucFirst i) ++ " as " ++ ucFirst i

    blank

    let code = codeToList $ runCodeGen' cfg $
          forM_ (filter (not . (`elem` ignore) . GI.API.name . fst) apis)
          (uncurry genCode)
    mapM_ (\c -> tell c >> blank) code

    where ignore = [
            "dummy_decl",
            -- These API elements refer to symbols which are
            -- dynamically loaded, which ghci has trouble with. Skip
            -- them.
            "IOModule",
            "io_modules_load_all_in_directory",
            "io_modules_load_all_in_directory_with_scope",
            -- We can skip in the bindings
            "signal_set_va_marshaller",
            -- These seem to have some issues in the introspection data
            "attribute_set_free", -- atk_attribute_set_free
            -- Accepts a NULL terminated array, but not
            -- marked as such in the bindings.
            "text_free_ranges", -- atk_text_free_ranges
            -- g_unichar_fully_decompose. "result" parameter is an
            -- array, but it is not marked as such.
            "unichar_fully_decompose",
            -- g_utf16_to_ucs4. "items_read" and "items_written" are
            -- out parameters, but they are marked as in parameters
            -- the introspection data.
            "utf16_to_ucs4",
            -- Same for the following functions
            "utf16_to_utf8",
            "utf8_to_ucs4",
            "utf8_to_ucs4_fast",
            "utf8_to_utf16",
            -- g_base64_decode_step, missing array length argument,
            -- requires more complex logic.
            "base64_decode_step",
            -- Similar to base64_decode_step
            "base64_encode_step",
            "base64_encode_close",
            -- g_ucs4_to_*, the first argument is marked as g_unichar, but it is really an array of g_unichar.
            "ucs4_to_utf16",
            "ucs4_to_utf8",
            -- g_regex_escape_string. Length can be -1, in which case
            -- it means zero terminated array of char.
            "regex_escape_string",
            -- g_signal_chain_from_overridden. Seems to be
            -- null-terminated, but it is not marked as such.
            "signal_chain_from_overridden",
            -- g_signal_emitv, same as g_signal_chain_from_overridden
            "signal_emitv" ]
