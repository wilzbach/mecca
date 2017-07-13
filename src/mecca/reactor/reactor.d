module mecca.reactor.reactor;

import std.exception;
import std.string;

import mecca.containers.lists;
import mecca.containers.arrays;
import mecca.containers.pools;
import mecca.lib.time;
import mecca.lib.reflection;
import mecca.lib.memory;
import mecca.log;
import mecca.reactor.time_queue;
import mecca.reactor.fibril: Fibril;
import core.memory: GC;
import core.sys.posix.sys.mman: munmap, mprotect, PROT_NONE;

import std.stdio;


struct ReactorFiber {
    enum FLS_BLOCK_SIZE = 512;

    struct OnStackParams {
        Closure                 fiberBody;
        GCStackDescriptor       stackDescriptor;
        ubyte[FLS_BLOCK_SIZE]   flsBlock;
    }
    enum Flags: ubyte {
        CALLBACK_SET   = 0x01,
        SCHEDULED      = 0x02,
        RUNNING        = 0x04,
        SPECIAL        = 0x08,
        IMMEDIATE      = 0x10,
        //HAS_EXCEPTION  = 0x20,
        //REQUEST_BT     = 0x40,
    }

align(1):
    Fibril              fibril;
    OnStackParams*      params;
    ReactorFiber*       _next;
    uint                incarnationCounter;
    ubyte               _flags;
    ubyte[3]            _reserved;

    static assert (this.sizeof == 32);  // keep it small and cache-line friendly

    void setup(void[] stackArea) nothrow @nogc {
        fibril.set(stackArea[0 .. $ - OnStackParams.sizeof], &wrapper);
        params = cast(OnStackParams*)&stackArea[$ - OnStackParams.sizeof];
        setToInit(params);

        params.stackDescriptor.bstack = params;
        params.stackDescriptor.tstack = fibril.rsp;
        params.stackDescriptor.add();

        _next = null;
        incarnationCounter = 0;
        _flags = 0;
    }

    void teardown() nothrow @nogc {
        fibril.reset();
        if (params) {
            params.stackDescriptor.remove();
            params = null;
        }
    }

    @property uint identity() const nothrow @nogc {
        return cast(uint)(&this - theReactor.allFibers.ptr);
    }

    @property bool flag(string NAME)() const pure nothrow @nogc {
        return (_flags & __traits(getMember, Flags, NAME)) != 0;
    }
    @property void flag(string NAME)(bool value) pure nothrow @nogc {
        if (value) {
            _flags |= __traits(getMember, Flags, NAME);
        }
        else {
            _flags &= ~__traits(getMember, Flags, NAME);
        }
    }

    private void updateStackDescriptor() nothrow @nogc {
        params.stackDescriptor.tstack = fibril.rsp;
    }

    private void wrapper() nothrow {
        while (true) {
            INFO!"wrapper on %s flags=0x%0x"(identity, _flags);

            assert (theReactor.thisFiber is &this, "this is wrong");
            assert (flag!"RUNNING");
            Throwable ex = null;

            try {
                params.fiberBody();
            }
            catch (Throwable ex2) {
                ex = ex2;
            }

            INFO!"wrapper finished on %s, ex=%s"(identity, ex);

            params.fiberBody.clear();
            flag!"RUNNING" = false;
            flag!"CALLBACK_SET" = false;
            incarnationCounter++;
            theReactor.fiberTerminated(ex);
        }
    }
}


struct FiberHandle {
    uint identity = uint.max;
    uint incarnation = uint.max;

    this(ReactorFiber* fib) @nogc nothrow {
        opAssign(fib);
    }
    auto ref opAssign(ReactorFiber* fib) @nogc nothrow {
        if (fib) {
            identity = fib.identity;
            incarnation = fib.incarnationCounter;
        }
        else {
            identity = uint.max;
        }
        return this;
    }
    @property ReactorFiber* get() const {
        if (identity == uint.max || theReactor.allFibers[identity].incarnationCounter != incarnation) {
            return null;
        }
        return &theReactor.allFibers[identity];
    }

    @property bool isValid() const {
        return get() !is null;
    }
}


struct Reactor {
private:
    enum MAX_IDLE_CALLBACKS = 16;
    enum TIMER_NUM_BINS = 256;
    enum TIMER_NUM_LEVELS = 3;

    enum NUM_SPECIAL_FIBERS = 2;
    enum ZERO_DURATION = Duration.zero;

    struct Options {
        uint     numFibers = 256;
        size_t   fiberStackSize = 32*1024;
        Duration gcInterval = 30.seconds;
        Duration timerGranularity = 1.msecs;
        size_t   numTimers = 10000;
    }

    bool _open;
    bool _running;
    int criticalSectionNesting;
    ulong idleCycles;
    Options options;

    MmapBuffer fiberStacks;
    MmapArray!ReactorFiber allFibers;
    LinkedQueueWithLength!(ReactorFiber*) freeFibers;
    LinkedQueueWithLength!(ReactorFiber*) scheduledFibers;

    ReactorFiber* thisFiber;
    ReactorFiber* prevFiber;
    ReactorFiber* mainFiber;
    ReactorFiber* idleFiber;
    alias IdleCallbackDlg = void delegate(Duration);
    FixedArray!(IdleCallbackDlg, MAX_IDLE_CALLBACKS) idleCallbacks;

    struct TimedCallback {
        TimedCallback* _next, _prev;
        TscTimePoint timePoint;

        Closure closure;
    }

    // TODO change to mmap pool or something
    SimplePool!(TimedCallback) timedCallbacksPool;
    CascadingTimeQueue!(TimedCallback*, TIMER_NUM_BINS, TIMER_NUM_LEVELS) timeQueue;

public:
    @property bool isOpen() const pure nothrow @nogc {
        return _open;
    }

    void setup() {
        assert (!_open, "reactor.setup called twice");
        _open = true;
        assert (options.numFibers > NUM_SPECIAL_FIBERS);

        const stackPerFib = (((options.fiberStackSize + SYS_PAGE_SIZE - 1) / SYS_PAGE_SIZE) + 1) * SYS_PAGE_SIZE;
        fiberStacks.allocate(stackPerFib * options.numFibers);
        allFibers.allocate(options.numFibers);

        thisFiber = null;
        criticalSectionNesting = 0;
        idleCallbacks.length = 0;

        foreach(i, ref fib; allFibers) {
            auto stack = fiberStacks[i * stackPerFib .. (i + 1) * stackPerFib];
            //errnoEnforce(mprotect(stack.ptr, SYS_PAGE_SIZE, PROT_NONE) == 0);
            errnoEnforce(munmap(stack.ptr, SYS_PAGE_SIZE) == 0, "munmap");
            fib.setup(stack[SYS_PAGE_SIZE .. $]);

            if (i >= NUM_SPECIAL_FIBERS) {
                freeFibers.append(&fib);
            }
        }

        mainFiber = &allFibers[0];
        mainFiber.flag!"SPECIAL" = true;
        mainFiber.flag!"CALLBACK_SET" = true;

        idleFiber = &allFibers[1];
        idleFiber.flag!"SPECIAL" = true;
        idleFiber.flag!"CALLBACK_SET" = true;
        idleFiber.params.fiberBody.set(&idleLoop);

        timedCallbacksPool.open(options.numTimers, true);
        timeQueue.open(options.timerGranularity);
    }

    void teardown() {
        assert(_open, "reactor teardown called on non-open reactor");
        assert(!_running, "reactor teardown called on still running reactor");
        assert(criticalSectionNesting==0);

        // XXX: go over all scheduled/pending fibers and throwInFiber(ReactorExit)

        options.setToInit();
        allFibers.free();
        fiberStacks.free();
        timedCallbacksPool.close();

        setToInit(freeFibers);
        setToInit(scheduledFibers);

        thisFiber = null;
        prevFiber = null;
        mainFiber = null;
        idleFiber = null;
        idleCallbacks.length = 0;
        idleCycles = 0;

        _open = false;
    }

    void registerIdleCallback(IdleCallbackDlg dg) {
        // You will notice our deliberate lack of function to unregister
        idleCallbacks ~= dg;
        DEBUG!"%s idle callbacks registered"(idleCallbacks.length);
    }

    FiberHandle spawnFiber(T...)(T args) {
        auto fib = _spawnFiber(false);
        fib.params.fiberBody.set(args);
        return FiberHandle(fib);
    }

    @property bool isIdle() pure const nothrow @nogc {
        return thisFiber is idleFiber;
    }
    @property bool isMain() pure const nothrow @nogc {
        return thisFiber is mainFiber;
    }
    @property bool isSpecialFiber() const nothrow @nogc {
        return thisFiber.flag!"SPECIAL";
    }
    @property FiberHandle runningFiberHandle() nothrow @nogc {
        // XXX This assert may be incorrect, but it is easier to remove an assert than to add one
        assert(!isSpecialFiber, "Should not blindly get fiber handle of special fibers");
        return FiberHandle(thisFiber);
    }

    void start() {
        INFO!"Starting reactor"();
        assert( idleFiber !is null, "Reactor started without calling \"setup\" first" );
        mainloop();
    }

    void stop() {
        if (_running) {
            _running = false;
            if (thisFiber !is mainFiber) {
                resumeSpecialFiber(mainFiber);
            }
        }
    }

    void enterCriticalSection() pure nothrow @nogc {
        pragma(inline, true);
        criticalSectionNesting++;
    }

    void leaveCriticalSection() pure nothrow @nogc {
        pragma(inline, true);
        assert (criticalSectionNesting > 0);
        criticalSectionNesting--;
    }
    @property bool isInCriticalSection() const pure nothrow @nogc {
        return criticalSectionNesting > 0;
    }

    @property auto criticalSection() {
        pragma(inline, true);
        struct CriticalSection {
            @disable this(this);
            ~this() {theReactor.leaveCriticalSection();}
        }
        enterCriticalSection();
        return CriticalSection();
    }

    void yieldThisFiber() {
        resumeFiber(thisFiber);
        suspendThisFiber();
    }

    struct TimerHandle {
    private:
        TimedCallback* callback;
    }

    TimerHandle registerTimer(Closure closure, Timeout timeout) {
        TimedCallback* callback = timedCallbacksPool.alloc();
        callback.closure = closure;
        callback.timePoint = timeout.expiry;

        timeQueue.insert(callback);

        return TimerHandle(callback);
    }

    void cancelTimer(TimerHandle handle) {
        assert(false, "TODO implement");
    }

    void delay(Duration duration) {
        delay(Timeout(duration));
    }

    void delay(Timeout until) {
        assert(until != Timeout.init, "Delay argument uninitialized");
        Closure closure;
        closure.set(&resumeFiber, runningFiberHandle);

        auto timerHandle = registerTimer(closure, until);
        scope(failure) cancelTimer(timerHandle);

        suspendThisFiber();
    }

private:
    @property bool shouldRunTimedCallbacks() {
        return timeQueue.cyclesTillNextEntry(TscTimePoint.now()) == 0;
    }

    void switchToNext() {
        DEBUG!"SWITCH out of %s"(thisFiber.identity);

        // in source fiber
        {
            if (thisFiber !is mainFiber && !mainFiber.flag!"SCHEDULED" && shouldRunTimedCallbacks()) {
                resumeSpecialFiber(mainFiber);
            }
            else if (scheduledFibers.empty) {
                resumeSpecialFiber(idleFiber);
            }

            assert (!scheduledFibers.empty, "scheduledList is empty");

            prevFiber = thisFiber;
            prevFiber.flag!"RUNNING" = false;

            thisFiber = scheduledFibers.popHead();
            assert (thisFiber.flag!"SCHEDULED");

            thisFiber.flag!"RUNNING" = true;
            thisFiber.flag!"SCHEDULED" = false;

            if (prevFiber !is thisFiber) {
                // make the switch
                prevFiber.fibril.switchTo(thisFiber.fibril);
            }
        }

        // in destination fiber
        {
            // note that GC cannot happen here since we disabled it in the mainloop() --
            // otherwise this might have been race-prone
            prevFiber.updateStackDescriptor();
            DEBUG!"SWITCH into %s"(thisFiber.identity);
        }
    }

    void fiberTerminated(Throwable ex) nothrow {
        assert (!thisFiber.flag!"SPECIAL", "special fibers must never terminate");
        assert (ex is null, ex.msg);

        freeFibers.prepend(thisFiber);

        try {
            /+if (ex) {
                mainFiber.setException(ex);
                resumeSpecialFiber(mainFiber);
            }+/
            switchToNext();
        }
        catch (Throwable ex2) {
            ERROR!"switchToNext failed with exception %s"(ex2);
            assert(false);
        }
    }

    package void suspendThisFiber(Timeout timeout = Timeout.infinite) {
        assert(timeout == Timeout.infinite, "Timers not yet properly implemented");
        //LOG("suspend");
        assert (!isInCriticalSection);
        switchToNext();
    }

    void resumeSpecialFiber(ReactorFiber* fib) {
        assert (fib.flag!"SPECIAL");
        assert (fib.flag!"CALLBACK_SET");
        assert (!fib.flag!"SCHEDULED" || scheduledFibers.head is fib);

        if (!fib.flag!"SCHEDULED") {
            fib.flag!"SCHEDULED" = true;
            scheduledFibers.prepend(fib);
        }
    }

    package void resumeFiber(FiberHandle handle) {
        resumeFiber(handle.get());
    }

    void resumeFiber(ReactorFiber* fib) {
        assert (!fib.flag!"SPECIAL");
        assert (fib.flag!"CALLBACK_SET");

        if (!fib.flag!"SCHEDULED") {
            fib.flag!"SCHEDULED" = true;
            if (fib.flag!"IMMEDIATE") {
                fib.flag!"IMMEDIATE" = false;
                scheduledFibers.prepend(fib);
            }
            else {
                scheduledFibers.append(fib);
            }
        }
    }

    ReactorFiber* _spawnFiber(bool immediate) {
        auto fib = freeFibers.popHead();
        assert (!fib.flag!"CALLBACK_SET");
        fib.flag!"IMMEDIATE" = immediate;
        fib.flag!"CALLBACK_SET" = true;
        resumeFiber(fib);
        return fib;
    }

    void idleLoop() {
        while (true) {
            TscTimePoint start, end;
            end = start = TscTimePoint.now;

            while (scheduledFibers.empty) {
                //enterCriticalSection();
                //scope(exit) leaveCriticalSection();
                end = TscTimePoint.now;
                /*
                   Since we've updated "end" before calling the timers, these timers won't count as idle time, unless....
                   after running them the scheduledFibers list is still empty, in which case they do.
                 */
                if( runTimedCallbacks(end) )
                    continue;

                // We only reach here if runTimedCallbacks did nothing, in which case "end" is recent enough
                Duration sleepDuration = timeQueue.timeTillNextEntry(end);
                DEBUG!"Got %s idle callbacks registered"(idleCallbacks.length);
                if( idleCallbacks.length==1 ) {
                    DEBUG!"idle callback called with duration %s"(sleepDuration);
                    idleCallbacks[0](sleepDuration);
                } else if ( idleCallbacks.length>1 ) {
                    foreach(cb; idleCallbacks) {
                        cb(ZERO_DURATION);
                    }
                } else {
                    WARN!"Idle thread called with no callbacks, sleeping %s"(sleepDuration);
                    import core.thread; Thread.sleep(sleepDuration);
                }
            }
            idleCycles += end.diff!"cycles"(start);
            switchToNext();
        }
    }

    bool runTimedCallbacks(TscTimePoint now = TscTimePoint.now) {
        bool ret;

        TimedCallback* callback;
        while ((callback = timeQueue.pop(now)) !is null) {
            callback.closure();
            timedCallbacksPool.release(callback);

            ret = true;
        }

        return ret;
    }

    void mainloop() {
        assert (_open);
        assert (!_running);
        assert (thisFiber is null);

        _running = true;
        GC.disable();
        scope(exit) GC.enable();

        thisFiber = mainFiber;
        scope(exit) thisFiber = null;

        while (_running) {
            runTimedCallbacks();
            switchToNext();
        }
    }
}


__gshared Reactor theReactor;


unittest {
    import std.stdio;

    theReactor.setup();
    scope(exit) theReactor.teardown();

    static void fibFunc(string name) {
        foreach(i; 0 .. 10) {
            writeln(name);
            theReactor.yieldThisFiber();
        }
        theReactor.stop();
    }

    theReactor.spawnFiber(&fibFunc, "hello");
    theReactor.spawnFiber(&fibFunc, "world");
    theReactor.start();
}

unittest {
    // Test simple timeout
    import std.stdio;
    import mecca.reactor.fd;

    theReactor.setup();
    scope(exit) theReactor.teardown();
    FD.openReactor();

    uint counter;
    TscTimePoint start;

    void fiberFunc(Duration duration) {
        INFO!"Fiber %s sleeping for %s"(theReactor.runningFiberHandle, duration);
        theReactor.delay(duration);
        auto now = TscTimePoint.now;
        counter++;
        INFO!"Fiber %s woke up after %s, overshooting by %s counter is %s"(theReactor.runningFiberHandle, now - start,
                (now-start) - duration, counter);
    }

    void ender() {
        INFO!"Fiber %s ender is sleeping for 250ms"(theReactor.runningFiberHandle);
        theReactor.delay(dur!"msecs"(250));
        INFO!"Fiber %s ender woke up"(theReactor.runningFiberHandle);

        theReactor.stop();
    }

    theReactor.spawnFiber(&fiberFunc, dur!"msecs"(10));
    theReactor.spawnFiber(&fiberFunc, dur!"msecs"(100));
    theReactor.spawnFiber(&fiberFunc, dur!"msecs"(150));
    theReactor.spawnFiber(&fiberFunc, dur!"msecs"(20));
    theReactor.spawnFiber(&fiberFunc, dur!"msecs"(30));
    theReactor.spawnFiber(&fiberFunc, dur!"msecs"(200));
    theReactor.spawnFiber(&ender);

    start = TscTimePoint.now;
    theReactor.start();
    auto end = TscTimePoint.now;
    INFO!"UT finished in %s"(end - start);

    assert(counter == 6, "Not all fibers finished");
}