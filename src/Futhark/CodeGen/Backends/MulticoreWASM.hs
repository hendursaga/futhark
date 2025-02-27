-- | C code generator.  This module can convert a correct ImpCode
-- program to an equivalent C program.  This C program is expected to
-- be converted to WebAssembly, so we also produce the intended
-- JavaScript wrapper.
module Futhark.CodeGen.Backends.MulticoreWASM
  ( compileProg,
    runServer,
    libraryExports,
    GC.CParts (..),
    GC.asLibrary,
    GC.asExecutable,
    GC.asServer,
  )
where

import Data.Maybe
import Data.Text qualified as T
import Futhark.CodeGen.Backends.GenericC qualified as GC
import Futhark.CodeGen.Backends.GenericWASM
import Futhark.CodeGen.Backends.MulticoreC qualified as MC
import Futhark.CodeGen.ImpCode.Multicore qualified as Imp
import Futhark.CodeGen.ImpGen.Multicore qualified as ImpGen
import Futhark.IR.MCMem
import Futhark.MonadFreshNames

-- | Compile Futhark program to wasm-multicore program (some assembly
-- required).
--
-- The triple that is returned consists of
--
-- * Generated C code (to be passed to Emscripten).
--
-- * JavaScript wrapper code that presents a nicer interface to the
--   Emscripten-produced code (this should be put in a @.class.js@
--   file by itself).
--
-- * Options that should be passed to @emcc@.
compileProg ::
  MonadFreshNames m =>
  T.Text ->
  Prog MCMem ->
  m (ImpGen.Warnings, (GC.CParts, T.Text, [String]))
compileProg version prog = do
  (ws, prog') <- ImpGen.compileProg prog

  prog'' <-
    GC.compileProg
      "wasm_multicore"
      version
      MC.operations
      MC.generateContext
      ""
      (DefaultSpace, [DefaultSpace])
      MC.cliOptions
      prog'

  pure
    ( ws,
      ( prog'',
        javascriptWrapper (fRepMyRep prog'),
        "_futhark_context_config_set_num_threads" : emccExportNames (fRepMyRep prog')
      )
    )

fRepMyRep :: Imp.Definitions Imp.Multicore -> [JSEntryPoint]
fRepMyRep prog =
  let Imp.Functions fs = Imp.defFuns prog
      function (Imp.Function entry _ _ _) = do
        Imp.EntryPoint n res args <- entry
        Just $
          JSEntryPoint
            { name = nameToString n,
              parameters = map (extToString . snd) args,
              ret = map (extToString . snd) res
            }
   in mapMaybe (function . snd) fs
