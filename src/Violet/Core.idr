module Violet.Core

import System
import Control.App
import Control.App.Console
import Data.List
import Data.String
import Text.Bounded
import Violet.Core.Term
import public Violet.Core.Eval
import public Violet.Error.Check

CtorSet : Type
CtorSet = List (Name, List VTy)

public export
record CheckState where
	constructor MkCheckState
	topCtx : Ctx
	topEnv : GlobalEnv
	dataDefs : List (Name, CtorSet)

export
checkState : Ctx -> CheckState
checkState ctx = MkCheckState ctx [] []

export
interface Has [Exception CheckError, State CheckState CheckState] e => Check e where
	getState : App e CheckState
	putState : CheckState -> App e ()

	updateEnv : Name -> Val -> App e ()
	updateCtx : Name -> VTy -> App e ()

	-- add inductive data type
	addIndType : Name -> CtorSet -> App e ()
	-- find constructor set for data type
	findCtorSet : Name -> App e CtorSet

	report : CheckErrorKind -> App e a
	addPos : Bounds -> App e a -> App e a
export
Has [Exception CheckError, State CheckState CheckState] e => Check e where
	getState = get CheckState
	putState = put CheckState

	updateEnv x v = do
		state <- getState
		putState $ { topEnv := (x, v) :: state.topEnv } state
	updateCtx x vty = do
		state <- getState
		putState $ { topCtx := extendCtx state.topCtx x vty } state

	addIndType dataName cs = do
		state <- getState
		putState $ { dataDefs := (dataName, cs) :: state.dataDefs } state
	findCtorSet dataName = do
		state <- getState
		Just cs <- pure $ lookup dataName state.dataDefs
			| Nothing => report $ NotADataType dataName
		pure cs

	report err = do
		state <- get CheckState
		let ctx = state.topCtx
		throw $ MkCheckError ctx.filename ctx.source Nothing err
	addPos bounds app = catch app
		(\ce => case ce.bounds of
			Nothing => let err : CheckError = {bounds := Just bounds} ce in throw err
			Just _ => throw ce)

export
runEval : Check es => (e -> a -> Either EvalError b) -> e -> a -> App es b
runEval f env a = do
	Right b <- pure $ f env a
		| Left e => report $ cast e
	pure b

mutual
	export
	checkModule : Check e => List Definition -> App e CheckState
	checkModule [] = getState
	checkModule (d :: ds) = go d *> checkModule ds
		where
			handleDataCase : Tm -> DataCase -> App e (Name, List VTy)
			handleDataCase returned_ty (C x tys) = do
				state <- getState
				let env = MkEnv state.topEnv []
				tys' <- for tys (runEval eval env)
				t' <- runEval eval env (foldr (\t, s => (Pi "_" t s)) returned_ty tys)
				updateCtx x t'
				updateEnv x (VCtor x [])
				pure (x, tys')

			go : Definition -> App e ()
			go (DSrcPos def) = addPos def.bounds (go def.val)
			go (Data dataName cases) = do
				updateCtx dataName VU
				updateEnv dataName (VData dataName)
				addIndType dataName !(for cases $ handleDataCase (Var dataName))
			go (Def x a t) = do
				state <- getState
				let env = MkEnv state.topEnv []
				a <- check env state.topCtx a VU
				a' <- runEval eval env a

				t <- check (MkEnv state.topEnv [(x, (VVar x))]) (extendCtx state.topCtx x a') t a'
				t' <- runEval eval env t
				updateEnv x t'
				updateCtx x a'

	export
	infer : Check e => Env -> Ctx -> Tm -> App e (Tm, VTy)
	infer env ctx tm = go tm
		where
			go : Tm -> App e (Tm, VTy)
			go (SrcPos t) = addPos t.bounds (go t.val)
			go (Var x) = case lookupCtx ctx x of
				Nothing => report (NoVar x)
				Just a => pure (Var x, a)
			go U = pure (U, VU)
			go (Apply t u) = do
				(t, VPi _ a b) <- infer env ctx t
					| (_, t') => report $ BadApp !(runEval quote env t')
				u <- check env ctx u a
				u' <- runEval eval env u
				Right b' <- pure $ b u'
					| Left e => report $ cast e
				pure (Apply t u, b')
			go (Lam {}) = report (InferLam tm)
			go (Pi x a b) = do
				a <- check env ctx a VU
				b <- check (extendEnv env x (VVar x)) (extendCtx ctx x !(runEval eval env a)) b VU
				pure (Pi x a b, VU)
			go (Let x a t u) = do
				a <- check env ctx a VU
				a' <- runEval eval env a
				t <- check env ctx t a'
				t' <- runEval eval env t
				(_, ty) <- infer (extendEnv env x t') (extendCtx ctx x a') u
				pure (Let x a t u, ty)
			go (Elim ts cases) = do
				tys <- for ts (infer env ctx)
				(cases', rhs_tys) <- foldlM
					(\(cases, ts), elim_case => do
						let (_, rhs) = elim_case
						(pats', ty) <- checkCase env ctx (map snd tys) elim_case
						pure ((pats', rhs) :: cases, ty :: ts))
					([], []) cases
				let tm = Elim ts cases'
				pure (tm, !(convTys (ElimInfer tm) env rhs_tys))
				where
					elabPattern : Name -> Name -> List Name -> Maybe (List VTy) -> App e (Pat, List (Name, VTy))
					-- when a pattern seems like a ctor, but it is not in constructor set, it's a variable pattern
					-- for example, `m` is var pattern when pattern matching on `Nat`
					elabPattern head x [] Nothing = pure (PVar head, [(head, VData x)])
					elabPattern head _ vars (Just tys) = pure (PCtor head vars, vars `zip` tys)
					elabPattern head x _ Nothing = report $ BadConstructor head x

					checkCase : Env -> Ctx -> List VTy -> ElimCase -> App e (List Pat, VTy)
					checkCase env ctx (VData x :: ts) (PCtor head vars :: pats, rhs) = do
						-- TODO: to enable indexed data type, we will need to extend `findCtorSet` in the future
						-- find a constructor set from definition context
						cs <- findCtorSet x
						(newPat, patCtx) <- elabPattern head x vars (lookup head cs)
						let patEnv : LocalEnv = case newPat of
						      PVar _ => [(head, VVar head)]
						      PCtor _ _ => (vars `zip` (map VVar vars))
						(pats, ty) <- checkCase ({ local := patEnv ++ env.local } env) (extendCtxWithBinds ctx $ patCtx) ts (pats, rhs)
						pure (newPat :: pats, ty)
					checkCase env ctx ([]) ([], rhs) = do
						(_, ty) <- infer env ctx rhs
						pure ([], ty)
					checkCase env ctx ts _ = report $ BadElimType !(for ts $ runEval quote env)

					convTys : CheckErrorKind -> Env -> List VTy -> App e VTy
					convTys err env (t :: t' :: ts) = do
						Right covertable <- pure $ conv env t t'
							| Left err => report $ cast err
						if covertable
							then pure t
							else report $ TypeMismatch !(runEval quote env t) !(runEval quote env t')
					convTys err env [t] = pure t
					convTys err env [] = report err

	check : Check e => Env -> Ctx -> Tm -> VTy -> App e Tm
	check env ctx t a = go t a
		where
			go : Tm -> VTy -> App e Tm
			go (SrcPos t) a = addPos t.bounds (go t.val a)
			go (Lam x t) (VPi x' a b) = do
				let x' = fresh env x'
				case b (VVar x') of
					Right u => Lam x <$> check (extendEnv env x (VVar x)) (extendCtx ctx x a) t u
					Left err => report $ cast err
			go (Let x a t u) _ = do
				a <- check env ctx a VU
				a' <- runEval eval env a
				t <- check env ctx t a'
				u <- check (extendEnv env x !(runEval eval env t)) (extendCtx ctx x a') u a'
				pure (Let x a t u)
			go _ expected = do
				(t', inferred) <- infer env ctx t
				Right convertable <- pure $ conv env inferred expected
					| Left err => report $ cast err
				if convertable
					then pure t'
					else report $ TypeMismatch !(runEval quote env expected) !(runEval quote env inferred)

	conv : Env -> Val -> Val -> Either EvalError Bool
	conv env t u = go t u
		where
			go : Val -> Val -> Either EvalError Bool
			go VU VU = pure True
			go (VPi x a b) (VPi _ a' b') = do
				let x' = fresh env x
				pure $ !(conv env a a') && !(conv (extendEnv env x' (VVar x')) !(b (VVar x')) !(b' (VVar x')))
			go (VLam x t) (VLam _ t') = do
				let x = fresh env x
				conv (extendEnv env x (VVar x)) !(t env.global (VVar x)) !(t' env.global (VVar x))
			-- checking eta conversion for Lam
			go (VLam x t) u = do
				let x = fresh env x
				conv (extendEnv env x (VVar x)) !(t env.global (VVar x)) (VApp u (VVar x))
			go u (VLam x t) = do
				let x = fresh env x
				conv (extendEnv env x (VVar x)) (VApp u (VVar x)) !(t env.global (VVar x))
			go (VVar x) (VVar x') = pure $ x == x'
			go (VData x) (VData x') = pure $ x == x'
			go (VApp t u) (VApp t' u') = pure $ !(conv env t t') && !(conv env u u')
			go _ _ = pure False
