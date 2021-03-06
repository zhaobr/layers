{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverlappingInstances #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

{-|

This module exports:

    1. The 'MonadWriter' type class and its operations 'writer', 'tell',
    'listen' and 'pass'.

    2. Instances of 'MonadWriter' for the relevant monad transformers from the
    @transformers@ package (lazy 'L.WriterT', strict 'WriterT', lazy 'L.RWST'
    and strict 'RWST').

    3. A universal pass-through instance of 'MonadWriter' for any existing
    @MonadWriter@ wrapped by a 'MonadLayer'.

    4. The utility operations 'listens' and 'censor'.

-}

module Control.Monad.Interface.Writer
    ( MonadWriter (writer, tell, listen, pass)
    , listens
    , censor
    )
where

-- base ----------------------------------------------------------------------
import           Control.Monad (liftM)
import           Data.Monoid (Monoid)


-- transformers --------------------------------------------------------------
import qualified Control.Monad.Trans.RWS.Lazy as L (RWST (RWST))
import           Control.Monad.Trans.RWS.Strict (RWST (RWST))
import qualified Control.Monad.Trans.Writer.Lazy as L (WriterT (WriterT))
import           Control.Monad.Trans.Writer.Strict (WriterT (WriterT))
import           Data.Functor.Product (Product (Pair))


-- layers --------------------------------------------------------------------
import           Control.Monad.Layer (MonadLayer (type Inner, layer))


------------------------------------------------------------------------------
-- | It is often desirable for a computation to generate output \"on the
-- side\". Logging and tracing are the most common examples in which data is
-- generated during a computation that we want to retain but is not the
-- primary result of the computation.
--
-- Explicitly managing the logging or tracing data can clutter up the code and
-- invite subtle bugs such as missed log entries. The 'MonadWriter' interface
-- provides a cleaner way to manage the output without cluttering the main
-- computation.
--
-- Minimal complete definition: 'listen', 'pass' and one of either 'writer' or
-- 'tell'.
class (Monad m, Monoid w) => MonadWriter w m | m -> w where
    -- | @'writer' (a,w)@ embeds a simple writer action.
    writer :: (a,w) -> m a

    -- | @'tell' w@ is an action that produces the output @w@.
    tell :: w -> m ()

    -- | @'listen' m@ is an action that executes the action @m@ and adds its
    -- output to the value of the computation.
    listen :: m a -> m (a, w)

    -- | @'pass' m@ is an action that executes the action @m@, which returns a
    -- value and a function, and returns the value, applying the function to
    -- the output.
    pass :: m (a, w -> w) -> m a

    writer ~(a, w) = tell w >> return a
    {-# INLINE writer #-}

    tell w = writer ((),w)
    {-# INLINE tell #-}


------------------------------------------------------------------------------
instance (Monad m, Monoid w) => MonadWriter w (L.WriterT w m) where
    writer = L.WriterT . return
    {-# INLINE writer #-}
    tell w = L.WriterT $ return ((), w)
    {-# INLINE tell #-}
    listen (L.WriterT m) = L.WriterT $ liftM (\(a, w) -> ((a, w), w)) m
    {-# INLINE listen #-}
    pass (L.WriterT m) = L.WriterT $ liftM (\((a, f), w) -> (a, f w)) m
    {-# INLINE pass #-}


------------------------------------------------------------------------------
instance (Monad m, Monoid w) => MonadWriter w (WriterT w m) where
    writer = WriterT . return
    {-# INLINE writer #-}
    tell w = WriterT $ return ((), w)
    {-# INLINE tell #-}
    listen (WriterT m) = WriterT $ liftM (\(a, w) -> ((a, w), w)) m
    {-# INLINE listen #-}
    pass (WriterT m) = WriterT $ liftM (\((a, f), w) -> (a, f w)) m
    {-# INLINE pass #-}


------------------------------------------------------------------------------
instance (Monad m, Monoid w) => MonadWriter w (L.RWST r w s m) where
    writer (a, w) = L.RWST $ \_ s -> return (a, s, w)
    {-# INLINE writer #-}
    tell w = L.RWST $ \_ s -> return ((), s, w)
    {-# INLINE tell #-}
    listen (L.RWST m) = L.RWST $ \r s ->
        liftM (\(~(a, s', w)) -> ((a, w), s', w)) (m r s)
    {-# INLINE listen #-}
    pass (L.RWST m) = L.RWST $ \r s ->
        liftM (\(~((a, f), s', w)) -> (a, s', f w)) (m r s)
    {-# INLINE pass #-}


------------------------------------------------------------------------------
instance (Monad m, Monoid w) => MonadWriter w (RWST r w s m) where
    writer (a, w) = RWST $ \_ s -> return (a, s, w)
    {-# INLINE writer #-}
    tell w = RWST $ \_ s -> return ((), s, w)
    {-# INLINE tell #-}
    listen (RWST m) = RWST $ \r s ->
        liftM (\(a, s', w) -> ((a, w), s', w)) (m r s)
    {-# INLINE listen #-}
    pass (RWST m) = RWST $ \r s ->
        liftM (\((a, f), s', w) -> (a, s', f w)) (m r s)
    {-# INLINE pass #-}


------------------------------------------------------------------------------
instance (MonadWriter w f, MonadWriter w g) =>
    MonadWriter w (Product f g)
  where
    writer f = Pair (writer f) (writer f)
    {-# INLINE writer #-}
    tell w = Pair (tell w) (tell w)
    {-# INLINE tell #-}
    listen (Pair f g) = Pair (listen f) (listen g)
    {-# INLINE listen #-}
    pass (Pair f g) = Pair (pass f) (pass g)
    {-# INLINE pass #-}


------------------------------------------------------------------------------
instance (MonadLayer m, MonadWriter w (Inner m)) => MonadWriter w m where
    writer = layer . writer
    {-# INLINE writer #-}
    tell = layer . tell
    {-# INLINE tell #-}
    listen m = m >>= layer . listen . return
    {-# INLINE listen #-}
    pass m = m >>= layer . pass . return
    {-# INLINE pass #-}


------------------------------------------------------------------------------
-- | @'listens' f m@ is an action that executes the action @m@ and adds the
-- result of applying @f@ to the output to the value of the computation.
--
-- > listens f m = liftM (\(~(a, w)) -> (a, f w)) (listen m)
listens :: MonadWriter w m => (w -> b) -> m a -> m (a, b)
listens f = liftM (\(~(a, w)) -> (a, f w)) . listen
{-# INLINE listens #-}


------------------------------------------------------------------------------
-- | @'censor' f m@ is an action that executes the action @m@ and
-- applies the function @f@ to its output, leaving the return value
-- unchanged.
--
-- > censor f m = pass (liftM (\a -> (a,f)) m)
censor :: MonadWriter w m => (w -> w) -> m a -> m a
censor f = pass . liftM (\a -> (a, f))
{-# INLINE censor #-}