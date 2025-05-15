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

    void writeSizeT(size_t value, size_t position) {
        position = position % bufferSize;
        // Use writeData to handle potential wraparound
        ubyte[size_t.sizeof] bytes = (cast(ubyte*)&value)[0..size_t.sizeof];
        writeData(bytes, position);
    }

    size_t readSizeT(size_t position) {
        position = position % bufferSize;
        // Use readData to handle potential wraparound
        ubyte[] bytes = readData(position, size_t.sizeof);
        return *(cast(size_t*)bytes.ptr);
    }

    void writeData(const ubyte[] data, size_t position) {
        enforce(data.length <= bufferSize, "Data too large for buffer");
        position = position % bufferSize;
        
        ubyte* buffer = getBuffer();
        for (size_t i = 0; i < data.length; i++) {
            buffer[(position + i) % bufferSize] = data[i];
        }
    }

    ubyte[] readData(size_t position, size_t length) {
        enforce(length <= bufferSize, "Data length exceeds buffer size");
        position = position % bufferSize;
        
        ubyte[] result = new ubyte[length];
        ubyte* buffer = getBuffer();
        for (size_t i = 0; i < length; i++) {
            result[i] = buffer[(position + i) % bufferSize];
        }
        return result;
    }

    size_t writeBuffer(const ubyte[] buffer, size_t position) {
        // First ensure we have enough total space available
        enforce(size_t.sizeof + buffer.length <= bufferSize, "Buffer too large for queue");
        
        // Write the length
        writeSizeT(buffer.length, position % bufferSize);
        
        // Write the data after the length, allowing wraparound
        size_t dataStart = (position + size_t.sizeof) % totalSize;
        writeData(buffer, dataStart);
        
        // Return the next write position
        return (dataStart + buffer.length) % bufferSize;
    }
    
    void writeNext(const ubyte[] buffer) {
        writePos = writeBuffer(buffer, writePos);
    }
    
    ubyte[] readBuffer(size_t position) {
        size_t length = readSizeT(position);
        enforce(length <= bufferSize, "Invalid buffer length");
        size_t dataStart = (position + size_t.sizeof) % bufferSize;
        return readData(dataStart, length);
    }
    
    ubyte[] readNext() {
        ubyte[] result = readBuffer(readPos);
        readPos = (readPos + size_t.sizeof + result.length) % bufferSize;
        return result;
    }

    size_t getUsedSpace() {
        return writePos >= readPos ? 
            writePos - readPos :
            totalSize - (readPos - writePos);
    }

    size_t getAvailableSpace() {
        return bufferSize - getUsedSpace();
    }
}

class JumboMessageQueue {
    private string _name;
    private int shmFd;
    private SharedState* state;
    private sem_t* mutex;
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

    void send(const ubyte[] data) {
        enforce(data.length + size_t.sizeof < state.bufferSize, "Message too large");

        sem_wait(mutex);
        scope(exit) sem_post(mutex);

        while (data.length + size_t.sizeof > state.getAvailableSpace()) {
            // Release mutex and wait for space to become available
            sem_post(mutex);
            sem_wait(spaceAvailable);  // Wait for signal that some space was freed
            sem_wait(mutex);
        }

        state.writeNext(data);
        sem_post(dataAvailable);
    }

    ubyte[] receive() {
        sem_wait(dataAvailable);
        sem_wait(mutex);
        scope(exit) sem_post(mutex);

        ubyte[] result = state.readNext();
        
        sem_post(spaceAvailable);
        return result;
    }

    void clear() {
        sem_wait(mutex);
        scope(exit) sem_post(mutex);

        // Reset state
        state.readPos = 0;
        state.writePos = 0;

        // Reset semaphores
        while (sem_trywait(dataAvailable) == 0) {} // Drain dataAvailable
        while (sem_trywait(spaceAvailable) == 0) {} // Drain spaceAvailable
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
        mutex = sem_open(toStringz("/" ~ _name ~ "_mutex"), O_CREAT, octal!"600", 1);
        enforce(mutex != SEM_FAILED, "Failed to create mutex semaphore");
        
        spaceAvailable = sem_open(toStringz("/" ~ _name ~ "_space"), O_CREAT, octal!"600", 0);
        enforce(spaceAvailable != SEM_FAILED, "Failed to create spaceAvailable semaphore");
        
        dataAvailable = sem_open(toStringz("/" ~ _name ~ "_data"), O_CREAT, octal!"600", 0);
        enforce(dataAvailable != SEM_FAILED, "Failed to create dataAvailable semaphore");

        if (isNew) {
            clear();
        }
    }

    private void cleanup() {
        if (state != null) munmap(state, state.totalSize);
        if (shmFd != -1) close(shmFd);
        if (mutex != null) sem_close(mutex);
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
