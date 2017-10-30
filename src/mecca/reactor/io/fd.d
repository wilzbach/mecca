/// Reactor aware FD (file descriptor) operations
module mecca.reactor.io.fd;

import core.stdc.errno;
import core.sys.posix.netinet.in_;
import core.sys.posix.netinet.tcp;
import unistd = core.sys.posix.unistd;
import fcntl = core.sys.posix.fcntl;
import core.sys.posix.sys.ioctl;
import core.sys.posix.sys.socket;
import core.sys.posix.sys.types;
import std.algorithm;
import std.traits;

import mecca.lib.exception;
import mecca.lib.io;
import mecca.lib.net;
import mecca.lib.string;
import mecca.lib.time;
import mecca.log;
import mecca.reactor.subsystems.epoll;

enum LISTEN_BACKLOG = 10;

private extern(C) nothrow @trusted @nogc {
    int pipe2(ref int[2], int flags);
}

/**
  Wrapper for datagram oriented socket (such as UDP)
 */
struct DatagramSocket {
    Socket sock;

    alias sock this;

    /**
     * Create a datagram socket
     *
     * This creates a SOCK_DATAGRAM socket.
     *
     * Params:
     *  bindAddr = a socket address for the server to connect to.
     *
     * Returns:
     *  Returns the newly created socket.
     *
     * Throws:
     * ErrnoException if the connection fails. Also throws this if one of the system calls fails.
     */
    static DatagramSocket create(SockAddr bindAddr) @safe @nogc {
        return DatagramSocket( Socket.socket(bindAddr.family, SOCK_SEQPACKET, 0) );
    }
}

/**
 * Wrapper for connection oriented datagram sockets.
 */
struct ConnectedDatagramSocket {
    Socket sock;

    alias sock this;

    /**
     * Create a stream socket and connect, as client, to the address supplied
     *
     * This creates a SOCK_SEQPACKET socket. It connects it to the designated server specified in sa, and waits, through the reactor, for
     * the connection to be established.
     *
     * Params:
     *  sa = a socket address for the server to connect to.
     *  timeout = the timeout for the connection. Throws TimeoutExpired if the timeout expires
     *
     * Returns:
     *  Returns the connected socket.
     *
     * Throws:
     * TimeoutExpired if the timeout expires
     *
     * ErrnoException if the connection fails (e.g. - ECONNREFUSED if connecting to a non-listening port). Also throws this if one of the
     *                  system calls fails.
     *
     * Anything else: May throw any exception injected using throwInFiber.
     */
    static ConnectedDatagramSocket connect(SockAddr sa, Timeout timeout = Timeout.infinite) @safe @nogc {
        ConnectedDatagramSocket ret = ConnectedDatagramSocket( Socket.socket(sa.family, SOCK_SEQPACKET, 0) );

        connectHelper(ret, sa, timeout);

        return ret;
    }

    /**
     * Create a datagram stream socket and bind, as a listening server, to the address supplied
     *
     * This creates a SOCK_SEQPACKET socket. It binds it to the designated address specified in sa and puts it in listening mode.
     *
     * Params:
     *  sa = a socket address for the server to listen on.
     *
     * Returns:
     *  Returns the listening socket.
     *
     * Throws:
     * ErrnoException if the connection fails (e.g. - EADDRINUSE if binding to a used port). Also throws this if one of the
     *                  system calls fails.
     */
    @notrace static ConnectedDatagramSocket listen(SockAddr sa) @trusted @nogc {
        ConnectedDatagramSocket sock = ConnectedDatagramSocket( Socket.socket(sa.family, SOCK_SEQPACKET, 0) );

        sock.osCallErrno!(.bind)(&sa.base, SockAddr.sizeof);
        sock.osCallErrno!(.listen)(LISTEN_BACKLOG);

        return sock;
    }

    /**
     * draws a new client connection from a listening socket
     *
     * This function waits for a client to connect to the socket. Once that happens, it returns with a ConnectedSocket for the new client.
     *
     * Params:
     *  clientAddr = an out parameter that receives the socket address of the client that connected.
     *
     * Returns:
     *  Returns the connected socket.
     *
     * Throws:
     * ErrnoException if the connection fails (e.g. - EINVAL if accepting from a non-listening socket, or ECONNABORTED if a connection was
     *                                         aborted). Also throws this if one of the system calls fails.
     *
     * Anything else: May throw any exception injected using throwInFiber.
     */
    @notrace ConnectedDatagramSocket accept(out SockAddr clientAddr) @trusted @nogc {
        socklen_t len = SockAddr.sizeof;
        int clientFd = sock.blockingCall!(.accept)(&clientAddr.base, &len);

        auto clientSock = ConnectedDatagramSocket( Socket( ReactorFD( clientFd ) ) );

        return clientSock;
    }
}

/**
 * Wrapper for connection oriented sockets.
 */
struct ConnectedSocket {
    Socket sock;

    alias sock this;

    /**
     * Create a stream socket and connect, as client, to the address supplied
     *
     * This creates a TCP socket (or equivalent for the address family). It connects it to the designated server specified in sa, and
     * waits, through the reactor, for the connection to be established.
     *
     * Params:
     *  sa = a socket address for the server to connect to.
     *  timeout = the timeout for the connection. Throws TimeoutExpired if the timeout expires
     *  nodelay = by default, Nagle algorithm is disabled for TCP connections. Setting this parameter to false reverts to the system-wide
     *         configuration.
     *
     * Returns:
     *  Returns the connected socket.
     *
     * Throws:
     * TimeoutExpired if the timeout expires
     *
     * ErrnoException if the connection fails (e.g. - ECONNREFUSED if connecting to a non-listening port). Also throws this if one of the
     *                  system calls fails.
     *
     * Anything else: May throw any exception injected using throwInFiber.
     */
    static ConnectedSocket connect(SockAddr sa, Timeout timeout = Timeout.infinite, bool nodelay = true) @safe @nogc {
        ConnectedSocket ret = ConnectedSocket( Socket.socket(sa.family, SOCK_STREAM, 0) );

        connectHelper(ret, sa, timeout);

        // Nagle is only defined for TCP/IPv*
        if( (sa.family == AF_INET || sa.family == AF_INET6) && nodelay ) {
            ret.setNagle(true);
        }

        return ret;
    }

    /**
     * Create a stream socket and bind, as a listening server, to the address supplied
     *
     * This creates a TCP socket (or equivalent for the address family). It binds it to the designated address specified in sa, and
     * puts it in listening mode.
     *
     * Params:
     *  sa = a socket address for the server to listen on.
     *
     * Returns:
     *  Returns the listening socket.
     *
     * Throws:
     * ErrnoException if the connection fails (e.g. - EADDRINUSE if binding to a used port). Also throws this if one of the
     *                  system calls fails.
     */
    @notrace static ConnectedSocket listen(SockAddr sa) @trusted @nogc {
        ConnectedSocket sock = ConnectedSocket( Socket.socket(sa.family, SOCK_STREAM, 0) );

        sock.osCallErrno!(.bind)(&sa.base, SockAddr.sizeof);
        sock.osCallErrno!(.listen)(LISTEN_BACKLOG);

        return sock;
    }

    /**
     * draws a new client connection from a listening socket
     *
     * This function waits for a client to connect to the socket. Once that happens, it returns with a ConnectedSocket for the new client.
     *
     * Params:
     *  clientAddr = an out parameter that receives the socket address of the client that connected.
     *  nodelay = by default, Nagle algorithm is disabled for TCP connections. Setting this parameter to false reverts to the system-wide
     *         configuration.
     *
     * Returns:
     *  Returns the connected socket.
     *
     * Throws:
     * ErrnoException if the connection fails (e.g. - EINVAL if accepting from a non-listening socket, or ECONNABORTED if a connection was
     *                                         aborted). Also throws this if one of the system calls fails.
     *
     * Anything else: May throw any exception injected using throwInFiber.
     */
    @notrace ConnectedSocket accept(out SockAddr clientAddr, bool nodelay = true) @trusted @nogc {
        socklen_t len = SockAddr.sizeof;
        int clientFd = sock.blockingCall!(.accept)(&clientAddr.base, &len);

        auto clientSock = ConnectedSocket( Socket( ReactorFD( clientFd ) ) );
        if( nodelay && (clientAddr.family == AF_INET || clientAddr.family == AF_INET6) )
            clientSock.setNagle(true);

        return clientSock;
    }

    /**
     * Enables or disables Nagle on a TCP socket
     *
     * Nagle is a packet aggregation algorithm employed over TCP. When enabled, under certain conditions, data sent gets delayed, hoping to
     * combine it with future data into less packets. The problem is that for request/response type protocols (such as HTTP), this algorithm
     * might result in increased latency.
     *
     * This function allows selectively enabling/disabling Nagle on TCP sockets.
     */
    void setNagle(bool on) @trusted @nogc {
        int flag = cast(int) on;
        sock.osCallErrno!(.setsockopt)( IPPROTO_TCP, TCP_NODELAY, &flag, flag.sizeof );
    }
}

private void connectHelper(ref Socket sock, SockAddr sa, Timeout timeout) @trusted @nogc {
    int result = sock.osCall!(.connect)(&sa.base, SockAddr.sizeof);
    ASSERT!"connect returned unexpected value %s errno %s"(result<0 && errno == EINPROGRESS, result, errno);

    // Wait for connect to finish
    epoller.waitForEvent(sock.ctx, timeout);

    socklen_t reslen = result.sizeof;
    sock.osCallErrno!(.getsockopt)( SOL_SOCKET, SO_ERROR, &result, &reslen);

    if( result!=0 ) {
        errno = result;
        errnoEnforceNGC(false, "connect");
    }
}

/**
 * Base class for the different types of sockets
 */
struct Socket {
    ReactorFD fd;

    alias fd this;

    /**
     * send data over a connected socket
     */
    ssize_t send(const void[] data, int flags) @trusted @nogc {
        return fd.blockingCall!(.send)(data.ptr, data.length, flags);
    }

    /**
     * send data over an unconnected socket
     */
    ssize_t sendto(const void[] data, int flags, const ref SockAddr destAddr) @trusted @nogc {
        return fd.blockingCall!(.sendto)(data.ptr, data.length, flags, &destAddr.base, SockAddr.sizeof); 
    }

    /**
     * Implementation of sendmsg.
     */
    ssize_t sendmsg(const ref msghdr msg, int flags) @trusted @nogc {
        return fd.blockingCall!(.sendmsg)(&msg, flags);
    }

    /**
     * recv data from a connected socket
     *
     * Can be used on unconnected sockets as well, but then it is not possible to know who the sender was.
     */
    ssize_t recv(void[] buffer, int flags) @trusted @nogc {
        return fd.blockingCall!(.recv)(buffer.ptr, buffer.length, flags);
    }

    /**
     * recv data from an unconnected socket
     */
    ssize_t recvfrom(void[] buffer, int flags, out SockAddr srcAddr) @trusted @nogc {
        socklen_t addrLen = SockAddr.sizeof;
        return fd.blockingCall!(.recvfrom)(buffer.ptr, buffer.length, flags, &srcAddr.base, &addrLen);
    }

    /// Implement the recvmsg system call in a reactor friendly way.
    ssize_t recvmsg(ref msghdr msg, int flags) @trusted @nogc {
        return fd.blockingCall!(.recvmsg)(&msg, flags);
    }

    /**
     * Get the name of the current socket.
     */
    SockAddr getSockName() @trusted @nogc {
        SockAddr sa;
        socklen_t saLen = sa.sizeof;
        fd.osCallErrno!(.getsockname)(&sa.base, &saLen);

        return sa;
    }

    /**
     * get the name of the socket's peer (for connected sockets only)
     *
     * Throws: ErrnoException (ENOTCONN) if called on an unconnected socket.
     */
    SockAddr getPeerName() @trusted @nogc {
        SockAddr sa;
        socklen_t saLen = sa.sizeof;
        fd.osCallErrno!(.getpeername)(&sa.base, &saLen);

        return sa;
    }

private:
    @notrace static Socket socket(sa_family_t domain, int type, int protocol) @trusted @nogc {
        int fd = .socket(domain, type, protocol);
        errnoEnforceNGC( fd>=0, "socket creation failed" );

        return Socket( ReactorFD(fd) );
    }
}

unittest {
    import mecca.reactor;
    import mecca.reactor.sync.event;

    theReactor.setup();
    scope(exit) theReactor.teardown();

    openReactorEpoll();
    scope(exit) closeReactorEpoll();

    enum BUF_SIZE = 128;
    enum NUM_BUFFERS = 16384;
    SockAddr sa;
    Event evt;

    void server() {
        ConnectedSocket sock = ConnectedSocket.listen( SockAddr(SockAddrIPv4.any()) );
        sa = sock.getSockName();
        INFO!"Listening socket on %s"(sa.toString()); // TODO remove reliance on GC
        evt.set();

        SockAddr clientAddr;
        ConnectedSocket clientSock = sock.accept(clientAddr);

        char[BUF_SIZE] buffer;

        uint last;
        while( clientSock.read(buffer)==BUF_SIZE ) {
            assertEQ( *cast(uint*)buffer.ptr, last, "Got incorrect value from socket" );
            last++;
        }

        assertEQ( last, NUM_BUFFERS, "Did not get the expected number of buffers" );

        theReactor.stop();
    }

    void client() {
        evt.wait();
        INFO!"Connecting to %s"(sa.toString()); // TODO remove GC
        SockAddr serverAddr = SockAddrIPv4.loopback(sa.ipv4.port);
        ConnectedSocket sock = ConnectedSocket.connect( serverAddr );

        char[BUF_SIZE] buffer;
        foreach( uint i; 0..NUM_BUFFERS ) {
            (cast(uint*)buffer.ptr)[0] = i;
            sock.write( buffer );
        }
    }

    theReactor.spawnFiber(&server);
    theReactor.spawnFiber(&client);

    theReactor.start();
}

/// Reactor aware FD wrapper for pipes
struct Pipe {
    ReactorFD fd;

    alias fd this;

    /**
     * create an unnamed pipe pair
     *
     * Params:
     *  readEnd = `Pipe` struct to receive the reading (output) end of the pipe
     *  writeEnd = `Pipe` struct to receive the writing (input) end of the pipe
     */
    static void create(out Pipe readEnd, out Pipe writeEnd) @trusted @nogc {
        int[2] pipeRawFD;

        errnoEnforceNGC( pipe2(pipeRawFD, fcntl.O_NONBLOCK)>=0, "OS pipe creation failed" );

        readEnd = Pipe( ReactorFD( FD( pipeRawFD[0] ) ) );
        writeEnd = Pipe( ReactorFD( FD( pipeRawFD[1] ) ) );
    }
}

/// Reactor aware FD wrapper for files
struct File {
    ReactorFD fd;

    alias fd this;

    /**
     * Open a named file.
     *
     * Parameters are as defined for the open system call. `flags` must not have `O_CREAT` set (use the other overload for that case).
     */
    void open(string pathname, int flags) @trusted @nogc {
        DBG_ASSERT!"open called with O_CREAT but no file mode argument. Flags %x"( (flags & fcntl.O_CREAT)==0, flags );
        open(pathname, flags, 0);
    }

    /**
     * Open or create a named file.
     *
     * Parameters are as defined for the open system call.
     */
    void open(string pathname, int flags, mode_t mode) @trusted @nogc {
        ASSERT!"open called on already open file."(!fd.isValid);

        int osFd = fcntl.open(toStringzNGC(pathname), flags, mode);
        errnoEnforceNGC( osFd>=0, "Failed to open file" );

        fd = ReactorFD(osFd);
    }
}

/**
 * An FD capable of performing sleeping operations through the reactor, when necessary
 */
struct ReactorFD {
private:
    FD fd;
    Epoll.FdContext* ctx;

public:
    @disable this(this);

    /**
     * Constructor from existing mecca.lib.FD
     *
     * Params:
     * fd = bare OS fd. Ownership is handed to the ReactorFD.
     * alreadyNonBlocking = whether the OS fd has NONBLOCKING already set on it. Setting to true saves a call to fcntl, but will hang the
     *             reactor in some cases.
     */
    this(int fd, bool alreadyNonBlocking = false) @safe @nogc {
        this( FD(fd), alreadyNonBlocking );
    }

    /**
     * Constructor from existing mecca.lib.FD
     *
     * Params:
     * fd = an FD rvalue
     * alreadyNonBlocking = whether the OS fd has NONBLOCKING already set on it. Setting to true saves a call to fcntl, but will hang the
     *             reactor in some cases.
     */
    this(FD fd, bool alreadyNonBlocking = false) @safe @nogc {
        move( fd, this.fd );
        ctx = epoller.registerFD(this.fd, alreadyNonBlocking);
    }

    ~this() nothrow @safe @nogc {
        close();
    }

    /// Move semantics opAssign
    ref ReactorFD opAssign(ReactorFD rhs) nothrow @safe @nogc {
        swap( rhs.fd, fd );
        swap( rhs.ctx, ctx );

        return this;
    }

    /// Cleanly closes an FD
    void close() nothrow @safe @nogc {
        if( fd.isValid ) {
            assert(ctx !is null);

            epoller.deregisterFd( fd, ctx );

            fd.close();
            ctx = null;
        }
    }

    /// Tests for open descriptor
    @property bool isValid() const pure nothrow @safe @nogc {
        return fd.isValid;
    }

    /// Returns the underlying mecca.lib.io.FD
    @property ref FD get() nothrow @safe @nogc {
        return fd;
    }

    /// Perform reactor aware @safe read
    ssize_t read(void[] buffer) @trusted @nogc {
        return blockingCall!(unistd.read)( buffer.ptr, buffer.length );
    }

    /// Perform reactor aware @safe write
    ssize_t write(void[] buffer) @trusted @nogc {
        return blockingCall!(unistd.write)( buffer.ptr, buffer.length );
    }

    alias fcntl = osCallErrno!(.fcntl.fcntl);
    alias ioctl = osCallErrno!(.ioctl);

package:
    auto blockingCall(alias F)(Parameters!F[1 .. $] args) @system @nogc {
        static assert (is(Parameters!F[0] == int));
        static assert (isSigned!(ReturnType!F));

        while (true) {
            auto ret = fd.osCall!F(args);
            if (ret < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK) {
                    epoller.waitForEvent(ctx);
                }
                else {
                    throw mkExFmt!ErrnoException("%s(%s)", __traits(identifier, F), fd.fileNo);
                }
            }
            else {
                return ret;
            }
        }
    }

    auto osCall(alias F)(Parameters!F[1..$] args) nothrow @system @nogc {
        return fd.osCall!F(args);
    }

    auto osCallErrno(alias F)(Parameters!F[1..$] args) @system @nogc if(isSigned!(ReturnType!F) && isIntegral!(ReturnType!F)) {
        alias RetType = ReturnType!F;
        RetType ret = osCall!F(args);

        enum FuncFullName = fullyQualifiedName!F;

        import std.string : lastIndexOf;
        enum FuncName = FuncFullName[ lastIndexOf(FuncFullName, '.')+1 .. $ ];

        enum ErrorMessage = "Running " ~ FuncName ~ " failed";
        errnoEnforceNGC(ret>=0, ErrorMessage);

        return ret;
    }
}

void openReactorEpoll() {
    epoller.open();
}

void closeReactorEpoll() {
    epoller.close();
}

unittest {
    import core.sys.posix.sys.types;

    import mecca.lib.consts;
    import mecca.reactor;

    theReactor.setup();
    scope(exit) theReactor.teardown();

    openReactorEpoll();
    scope(exit) closeReactorEpoll();

    Pipe pipeRead, pipeWrite;
    Pipe.create(pipeRead, pipeWrite);

    void reader() {
        uint[1024] buffer;
        enum BUFF_SIZE = typeof(buffer).sizeof;
        uint lastNum = -1;

        // Send 2MB over the pipe
        ssize_t res;
        while((res = pipeRead.read(buffer))>0) {
            assert(res==BUFF_SIZE, "Short read from pipe");
            assert(buffer[0] == ++lastNum, "Read incorrect value from buffer");
        }

        errnoEnforceNGC(res==0, "Read failed from pipe");
        INFO!"Reader finished"();
        theReactor.stop();
    }

    void writer() {
        uint[1024] buffer;
        enum BUFF_SIZE = typeof(buffer).sizeof;

        // Send 2MB over the pipe
        while(buffer[0] < (2*MB/BUFF_SIZE)) {
            ssize_t res = pipeWrite.write(buffer);
            errnoEnforceNGC( res>=0, "Write failed on pipe");
            assert( res==BUFF_SIZE, "Short write to pipe" );
            buffer[0]++;
        }

        INFO!"Writer finished - closing pipe"();
        pipeWrite.close();
    }

    theReactor.spawnFiber(&reader);
    theReactor.spawnFiber(&writer);

    theReactor.start();
}