%
% (c) The AQUA Project, Glasgow University, 1994-1996
%
\section[DsCCall]{Desugaring \tr{_ccall_}s and \tr{_casm_}s}

\begin{code}
#include "HsVersions.h"

module DsCCall ( dsCCall ) where

IMP_Ubiq()

import CoreSyn

import DsMonad
import DsUtils

import CoreUtils	( coreExprType )
import Id		( dataConArgTys )
import Maybes		( maybeToBool )
import PprStyle		( PprStyle(..) )
import PprType		( GenType{-instances-} )
import Pretty
import PrelVals		( packStringForCId )
import PrimOp		( PrimOp(..) )
import Type		( isPrimType, maybeAppDataTyConExpandingDicts, maybeAppTyCon,
			  eqTy, maybeBoxedPrimType )
import TysPrim		( byteArrayPrimTy, realWorldTy,  realWorldStatePrimTy,
			  byteArrayPrimTyCon, mutableByteArrayPrimTyCon )
import TysWiredIn	( getStatePairingConInfo,
			  realWorldStateTy, stateDataCon, pairDataCon, unitDataCon,
			  stringTy
			)
import Util		( pprPanic, pprError, panic )
\end{code}

Desugaring of @ccall@s consists of adding some state manipulation,
unboxing any boxed primitive arguments and boxing the result if
desired.

The state stuff just consists of adding in
@PrimIO (\ s -> case s of { S# s# -> ... })@ in an appropriate place.

The unboxing is straightforward, as all information needed to unbox is
available from the type.  For each boxed-primitive argument, we
transform:
\begin{verbatim}
   _ccall_ foo [ r, t1, ... tm ] e1 ... em
   |
   |
   V
   case e1 of { T1# x1# ->
   ...
   case em of { Tm# xm# -> xm#
   ccall# foo [ r, t1#, ... tm# ] x1# ... xm#
   } ... }
\end{verbatim}

The reboxing of a @_ccall_@ result is a bit tricker: the types don't
contain information about the state-pairing functions so we have to
keep a list of \tr{(type, s-p-function)} pairs.  We transform as
follows:
\begin{verbatim}
   ccall# foo [ r, t1#, ... tm# ] e1# ... em#
   |
   |
   V
   \ s# -> case (ccall# foo [ r, t1#, ... tm# ] s# e1# ... em#) of
	  (StateAnd<r># result# state#) -> (R# result#, realWorld#)
\end{verbatim}

\begin{code}
dsCCall :: FAST_STRING	-- C routine to invoke
	-> [CoreExpr]	-- Arguments (desugared)
	-> Bool		-- True <=> might cause Haskell GC
	-> Bool		-- True <=> really a "_casm_"
	-> Type		-- Type of the result (a boxed-prim type)
	-> DsM CoreExpr

dsCCall label args may_gc is_asm result_ty
  = newSysLocalDs realWorldStateTy	`thenDs` \ old_s ->

    mapAndUnzipDs unboxArg (Var old_s : args)	`thenDs` \ (final_args, arg_wrappers) ->

    boxResult result_ty				`thenDs` \ (final_result_ty, res_wrapper) ->

    let
	the_ccall_op = CCallOp label is_asm may_gc
			       (map coreExprType final_args)
			       final_result_ty
    in
    mkPrimDs the_ccall_op (map VarArg final_args) `thenDs` \ the_prim_app ->
    let
	the_body = foldr ($) (res_wrapper the_prim_app) arg_wrappers
    in
    returnDs (Lam (ValBinder old_s) the_body)
\end{code}

\begin{code}
unboxArg :: CoreExpr			-- The supplied argument
	 -> DsM (CoreExpr,		-- To pass as the actual argument
		 CoreExpr -> CoreExpr	-- Wrapper to unbox the arg
		)
unboxArg arg

  -- Primitive types
  -- ADR Question: can this ever be used?  None of the PrimTypes are
  -- instances of the CCallable class.
  --
  -- SOF response:
  --    Oh yes they are, I've just added them :-) Having _ccall_ and _casm_
  --  that accept unboxed arguments is a Good Thing if you have a stub generator
  --  which generates the boiler-plate box-unbox code for you, i.e., it may help
  --  us nuke this very module :-)
  --
  | isPrimType arg_ty
  = returnDs (arg, \body -> body)

  -- Strings
  | arg_ty `eqTy` stringTy
  -- ToDo (ADR): - allow synonyms of Strings too?
  = newSysLocalDs byteArrayPrimTy		`thenDs` \ prim_arg ->
    mkAppDs (Var packStringForCId) [VarArg arg]	`thenDs` \ pack_appn ->
    returnDs (Var prim_arg,
	      \body -> Case pack_appn (PrimAlts []
						    (BindDefault prim_arg body))
    )

  | null data_cons
    -- oops: we can't see the data constructors!!!
  = can't_see_datacons_error "argument" arg_ty

  -- Byte-arrays, both mutable and otherwise; hack warning
  | is_data_type &&
    length data_con_arg_tys == 2 &&
    maybeToBool maybe_arg2_tycon &&
    (arg2_tycon ==  byteArrayPrimTyCon ||
     arg2_tycon ==  mutableByteArrayPrimTyCon)
    -- and, of course, it is an instance of CCallable
  = newSysLocalsDs data_con_arg_tys		`thenDs` \ vars@[ixs_var, arr_cts_var] ->
    returnDs (Var arr_cts_var,
	      \ body -> Case arg (AlgAlts [(the_data_con,vars,body)]
					      NoDefault)
    )

  -- Data types with a single constructor, which has a single, primitive-typed arg
  | maybeToBool maybe_boxed_prim_arg_ty
  = newSysLocalDs the_prim_arg_ty		`thenDs` \ prim_arg ->
    returnDs (Var prim_arg,
	      \ body -> Case arg (AlgAlts [(box_data_con,[prim_arg],body)]
					      NoDefault)
    )

  | otherwise
  = pprPanic "unboxArg: " (ppr PprDebug arg_ty)
  where
    arg_ty = coreExprType arg

    maybe_boxed_prim_arg_ty = maybeBoxedPrimType arg_ty
    (Just (box_data_con, the_prim_arg_ty)) = maybe_boxed_prim_arg_ty

    maybe_data_type 			   = maybeAppDataTyConExpandingDicts arg_ty
    is_data_type			   = maybeToBool maybe_data_type
    (Just (tycon, tycon_arg_tys, data_cons)) = maybe_data_type
    (the_data_con : other_data_cons)       = data_cons

    data_con_arg_tys = dataConArgTys the_data_con tycon_arg_tys
    (data_con_arg_ty1 : data_con_arg_ty2 : _) = data_con_arg_tys

    maybe_arg2_tycon = maybeAppTyCon data_con_arg_ty2
    Just (arg2_tycon,_) = maybe_arg2_tycon

can't_see_datacons_error thing ty
  = pprError "ERROR: Can't see the data constructor(s) for _ccall_/_casm_ "
	     (ppBesides [ppStr thing, ppStr "; type: ", ppr PprForUser ty])
\end{code}


\begin{code}
boxResult :: Type				-- Type of desired result
	  -> DsM (Type,			-- Type of the result of the ccall itself
		  CoreExpr -> CoreExpr)	-- Wrapper for the ccall
							-- to box the result
boxResult result_ty
  | null data_cons
  -- oops! can't see the data constructors
  = can't_see_datacons_error "result" result_ty

  -- Data types with a single constructor, which has a single, primitive-typed arg
  | (maybeToBool maybe_data_type) &&				-- Data type
    (null other_data_cons) &&					-- Just one constr
    not (null data_con_arg_tys) && null other_args_tys	&& 	-- Just one arg
    isPrimType the_prim_result_ty				-- of primitive type
  =
    newSysLocalDs realWorldStatePrimTy			`thenDs` \ prim_state_id ->
    newSysLocalDs the_prim_result_ty 			`thenDs` \ prim_result_id ->

    mkConDs stateDataCon [TyArg realWorldTy, VarArg (Var prim_state_id)]  `thenDs` \ new_state ->
    mkConDs the_data_con (map TyArg tycon_arg_tys ++ [VarArg (Var prim_result_id)]) `thenDs` \ the_result ->

    mkConDs pairDataCon
	    [TyArg result_ty, TyArg realWorldStateTy, VarArg the_result, VarArg new_state]
							`thenDs` \ the_pair ->
    let
	the_alt = (state_and_prim_datacon, [prim_state_id, prim_result_id], the_pair)
    in
    returnDs (state_and_prim_ty,
	      \prim_app -> Case prim_app (AlgAlts [the_alt] NoDefault)
    )

  -- Data types with a single nullary constructor
  | (maybeToBool maybe_data_type) &&				-- Data type
    (null other_data_cons) &&					-- Just one constr
    (null data_con_arg_tys)
  =
    newSysLocalDs realWorldStatePrimTy		`thenDs` \ prim_state_id ->

    mkConDs stateDataCon [TyArg realWorldTy, VarArg (Var prim_state_id)]
						`thenDs` \ new_state ->
    mkConDs pairDataCon
	    [TyArg result_ty, TyArg realWorldStateTy, VarArg (Var unitDataCon), VarArg new_state]
						`thenDs` \ the_pair ->

    let
	the_alt  = (stateDataCon, [prim_state_id], the_pair)
    in
    returnDs (realWorldStateTy,
	      \prim_app -> Case prim_app (AlgAlts [the_alt] NoDefault)
    )

  | otherwise
  = pprPanic "boxResult: " (ppr PprDebug result_ty)

  where
    maybe_data_type 			   = maybeAppDataTyConExpandingDicts result_ty
    Just (tycon, tycon_arg_tys, data_cons) = maybe_data_type
    (the_data_con : other_data_cons)       = data_cons

    data_con_arg_tys		           = dataConArgTys the_data_con tycon_arg_tys
    (the_prim_result_ty : other_args_tys)  = data_con_arg_tys

    (state_and_prim_datacon, state_and_prim_ty) = getStatePairingConInfo the_prim_result_ty
\end{code}

