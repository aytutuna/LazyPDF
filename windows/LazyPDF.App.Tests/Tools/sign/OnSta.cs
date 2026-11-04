using System.Runtime.ExceptionServices;
using System.Windows.Threading;

namespace LazyPDF.App.Tests;

internal static class OnSta
{
    /// <summary>Runs <paramref name="test"/> on a thread of its own that WPF drawing may use.</summary>
    public static void Run(Action test)
    {
        ExceptionDispatchInfo? error = null;
        var thread = new Thread(() =>
        {
            try
            {
                test();
            }
            catch (Exception e)
            {
                error = ExceptionDispatchInfo.Capture(e);
            }
            finally
            {
                Dispatcher.CurrentDispatcher.InvokeShutdown();
            }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();
        error?.Throw();
    }
}
