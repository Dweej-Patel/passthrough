namespace Passthrough.Core.Shell.Sessions;

/// <summary>
/// Runs actions one at a time, in the order queued, off the caller's thread: where the session manager calls its
/// attachments, so none of them runs under its lock and each may call back in. An action that throws is dropped.
/// </summary>
internal sealed class Callouts
{
    private readonly Lock _lock = new();
    private readonly Queue<Action> _queue = new();
    private bool _running;
    private int _suspended;

    public void Post(Action action)
    {
        lock (_lock)
        {
            _queue.Enqueue(action);
            if (_running || _suspended > 0) return;
            _running = true;
        }
        ThreadPool.UnsafeQueueUserWorkItem(_ => Drain(), null);
    }

    /// <summary>For tests: holds every action back until <see cref="Resume"/>.</summary>
    public void Suspend() { lock (_lock) _suspended++; }

    public void Resume()
    {
        lock (_lock)
        {
            if (--_suspended > 0 || _running || _queue.Count == 0) return;
            _running = true;
        }
        ThreadPool.UnsafeQueueUserWorkItem(_ => Drain(), null);
    }

    /// <summary>For tests: returns once everything queued so far has run.</summary>
    public void Flush(TimeSpan timeout)
    {
        using var done = new ManualResetEventSlim();
        Post(done.Set);
        done.Wait(timeout);
    }

    private void Drain()
    {
        while (true)
        {
            Action next;
            lock (_lock)
            {
                if (_queue.Count == 0 || _suspended > 0) { _running = false; return; }
                next = _queue.Dequeue();
            }
            try { next(); }
            catch (Exception) { /* an attachment's failure is its own */ }
        }
    }
}
