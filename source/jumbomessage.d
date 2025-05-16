module jumbomessage;

import core.sys.posix.sys.mman;
import core.sys.posix.fcntl;
import core.sys.posix.semaphore;
import core.sys.posix.unistd;
import std.conv;
import std.exception;
import std.string;
import core.thread;

struct SharedState {
    size_t readPos;
    size_t writePos;
    size_t bufferSize;
    ubyte[0] data;  // Flexible array member for buffer

    static SharedState* initialize(void* memory, size_t bufferSize) {
        auto state = cast(SharedState*)memory;
        state.readPos = 0;
        state.writePos = 0;
        state.bufferSize = bufferSize;
        return state;
    }

    private ubyte* getBuffer() {
        return (cast(ubyte*)&this) + SharedState.sizeof;  // Points to memory right after SharedState
    }
    
    size_t totalSize () {
        return SharedState.sizeof + ubyte.sizeof * bufferSize;
    }

    void writeSizeT(size_t value) {
        ubyte[size_t.sizeof] bytes = (cast(ubyte*)&value)[0..size_t.sizeof];
        writeData(bytes);
    }

    size_t readSizeT() {
        ubyte[] bytes = readData(size_t.sizeof);
        return *(cast(size_t*)bytes.ptr);
    }

    void writeData(const ubyte[] data) {
        assert(data.length <= bufferSize, "Data too large for buffer");
        size_t position = writePos % bufferSize;
        
        ubyte* buffer = getBuffer();
        for (size_t i = 0; i < data.length; i++) {
            buffer[(position + i) % bufferSize] = data[i];
        }
        writePos += data.length;
    }

    ubyte[] readData(size_t length) {
        assert(length <= bufferSize, "Data length exceeds buffer size");
        assert(readPos + length <= writePos, "Not enough data to read");

        size_t position = readPos % bufferSize;
        
        ubyte[] result = new ubyte[length];
        ubyte* buffer = getBuffer();
        for (size_t i = 0; i < length; i++) {
            result[i] = buffer[(position + i) % bufferSize];
        }
        readPos += length;
        return result;
    }

    void writeBuffer(const ubyte[] buffer) {
        // First ensure we have enough total space available
        assert(size_t.sizeof + buffer.length <= bufferSize, "Buffer too large for queue");
        assert(buffer.length <= getAvailableSpace(), "Not enough space to write buffer");
        
        // Write the length
        writeSizeT(buffer.length);
        
        writeData(buffer);
    }
    
    ubyte[] readBuffer() {
        size_t length = readSizeT();
        assert(length <= bufferSize, "Invalid buffer length");
        assert(length <= getUsedSpace(), "Not enough data to read");
        return readData(length);
    }
    
    size_t getUsedSpace() const {
        assert(writePos >= readPos, "Write position must be greater than or equal to read position");
        return writePos - readPos;
    }

    size_t getAvailableSpace() const {
        assert(bufferSize >= getUsedSpace(), "Buffer size must be greater than or equal to used space");
        return bufferSize - getUsedSpace();
    }
}

class JumboMessageQueue {
    private string _name;
    private int shmFd;
    private SharedState* state;
    private sem_t* queueMutex;  // Single mutex for all queue operations
    private sem_t* spaceAvailable;
    private sem_t* dataAvailable;
    private size_t shmSize = 1024 * 1024; // 1MB default

    this(string queueName, size_t size = 1024 * 1024) {
        this._name = queueName;
        this.shmSize = size;
        initResources();
    }

    ~this() {
        cleanup();
    }
    
    string name() {
        return _name;
    }

    int spaceAvailableValue() {
        return getSemValue(spaceAvailable);
    }

    int dataAvailableValue() {
        return getSemValue(dataAvailable);
    }

    void send(const ubyte[] data) {
        size_t spaceNeeded = data.length + size_t.sizeof;
        
        // Check space under queue mutex
        sem_wait(queueMutex);
        {
            scope(exit) sem_post(queueMutex);
            assert(getSemValue(queueMutex) == 0, "queueMutex should be 0 after waiting");

            enforce(spaceNeeded < state.bufferSize, "Message too large");
            
            while (state.getAvailableSpace() < spaceNeeded) {
                // Not enough space yet, release mutex and wait for more space
                sem_post(queueMutex);
                sem_wait(spaceAvailable);  // Wait for next space notification
                sem_wait(queueMutex);
            }
            
            state.writeBuffer(data);
            
            sem_post(dataAvailable);
        }
    }

    ubyte[] receive() {
        sem_wait(dataAvailable);

        sem_wait(queueMutex);
        {
            scope(exit) sem_post(queueMutex);
            assert(getSemValue(queueMutex) == 0, "queueMutex should be 0 after waiting");
            
            ubyte[] result = state.readBuffer();
            
            // Always signal that space is available after a read
            sem_post(spaceAvailable);
            
            return result;
        }
    }

    void clear() {
        // Acquire queue mutex
        sem_wait(queueMutex);
        scope(exit) sem_post(queueMutex);
        
        // Reset state
        state.readPos = 0;
        state.writePos = 0;
        
        // Reset semaphores
        int value;
        
        // Drain dataAvailable to 0
        while (sem_getvalue(dataAvailable, &value) == 0 && value > 0) {
            sem_wait(dataAvailable);
        }
        
        while (sem_getvalue(spaceAvailable, &value) == 0 && value > 0) {
            sem_wait(spaceAvailable);
        }
    }

    private void initResources() {
        // Calculate total size needed for SharedState plus buffer
        size_t totalSize = SharedState.sizeof + shmSize;

        // Try to open existing shared memory first
        shmFd = shm_open(toStringz("/" ~ _name), O_RDWR, octal!"600");
        bool isNew = false;
        if (shmFd == -1) {
            // Doesn't exist, create new
            shmFd = shm_open(toStringz("/" ~ _name), O_CREAT | O_RDWR, octal!"600");
            enforce(shmFd != -1, "Failed to create shared memory");
            enforce(ftruncate(shmFd, totalSize) == 0, "Failed to size shared memory");
            isNew = true;
        }

        // Map the shared memory
        void* ptr = mmap(null, totalSize, PROT_READ | PROT_WRITE, MAP_SHARED, shmFd, 0);
        enforce(ptr != MAP_FAILED, "Failed to map shared memory");
        state = cast(SharedState*)ptr;

        if (isNew) {
            // Initialize SharedState with correct buffer size
            state = SharedState.initialize(ptr, shmSize);
        }

        // Initialize semaphores
        queueMutex = sem_open(toStringz("/" ~ _name ~ "_mutex"), O_CREAT, octal!"600", 1);
        enforce(queueMutex != SEM_FAILED, "Failed to create queue mutex semaphore");
        
        spaceAvailable = sem_open(toStringz("/" ~ _name ~ "_space"), O_CREAT, octal!"600", 1);  // Binary semaphore, initially 1 since buffer is empty
        enforce(spaceAvailable != SEM_FAILED, "Failed to create spaceAvailable semaphore");
        
        dataAvailable = sem_open(toStringz("/" ~ _name ~ "_data"), O_CREAT, octal!"600", 0);
        enforce(dataAvailable != SEM_FAILED, "Failed to create dataAvailable semaphore");

        if (isNew) {
            clear();
        }
    }

    private int getSemValue(sem_t* sem) {
        int value;
        sem_getvalue(sem, &value);
        return value;
    }
    
    private bool isBinarySemaphore(sem_t* sem) {
        int value;
        sem_getvalue(sem, &value);
        return value == 1 || value == 0;
    }
    
    private void cleanup() {
        if (state != null) munmap(state, state.totalSize);
        if (shmFd != -1) close(shmFd);
        if (queueMutex != null) sem_close(queueMutex);
        if (spaceAvailable != null) sem_close(spaceAvailable);
        if (dataAvailable != null) sem_close(dataAvailable);
    }

    static void cleanup(string queueName) {
        shm_unlink(toStringz("/" ~ queueName));
        sem_unlink(toStringz("/" ~ queueName ~ "_mutex"));
        sem_unlink(toStringz("/" ~ queueName ~ "_space"));
        sem_unlink(toStringz("/" ~ queueName ~ "_data"));
    }
}

class QueueEmptyException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) {
        super(msg, file, line);
    }
}
