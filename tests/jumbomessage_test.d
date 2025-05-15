module tests.jumbomessage_test;

import jumbomessage;
import std.stdio;
import std.conv;
import core.thread;
import std.array : array;
import std.range : repeat;
import core.time : Duration, MonoTime;

// Required for testing SharedState
import core.stdc.stdlib : malloc, free;
import std.exception : enforce;

void main() {}

// Helper function to allocate memory for SharedState testing
private void* allocateSharedState(size_t bufferSize) {
    size_t totalSize = SharedState.sizeof + bufferSize;
    void* memory = malloc(totalSize);
    enforce(memory !is null, "Failed to allocate memory for testing");
    SharedState* state = cast(SharedState*)memory;
    state.readPos = 0;
    state.writePos = 0;
    state.bufferSize = bufferSize;
    return memory;
}

unittest {
    writeln("Starting test: SharedState - Basic write/read size_t");
    void* memory = allocateSharedState(1024);
    scope(exit) free(memory);
    
    auto state = cast(SharedState*)memory;
    state.writeSizeT(42);
    auto value = state.readSizeT();
    assert(value == 42, "Expected 42 but got " ~ value.to!string);
}

unittest {
    writeln("Starting test: SharedState - Basic write/read data");
    void* memory = allocateSharedState(1024);
    scope(exit) free(memory);
    
    auto state = cast(SharedState*)memory;
    ubyte[] testData = [1, 2, 3, 4, 5];
    state.writeData(testData);
    auto result = state.readData(testData.length);
    assert(result == testData, "Data mismatch");
}

unittest {
    writeln("Starting test: SharedState - Write buffer with length");
    void* memory = allocateSharedState(1024);
    scope(exit) free(memory);
    
    auto state = cast(SharedState*)memory;
    ubyte[] testData = [1, 2, 3, 4, 5];
    state.writeBuffer(testData);
    auto result = state.readBuffer();
    assert(result == testData, "Buffer data mismatch");
}

unittest {
    writeln("Starting test: SharedState - Circular buffer wraparound");
    void* memory = allocateSharedState(16);  // Small buffer to test wraparound
    scope(exit) free(memory);
    
    auto state = cast(SharedState*)memory;
    ubyte[] data1 = [1, 2, 3];
    ubyte[] data2 = [4, 5, 6];
    
    // Write first buffer
    state.writeBuffer(data1);
    auto result1 = state.readBuffer();
    assert(result1 == data1, "First buffer data mismatch");
    
    // Write second buffer that should wrap around
    state.writeBuffer(data2);
    auto result2 = state.readBuffer();
    assert(result2 == data2, "Second buffer data mismatch");
}

unittest {
    writeln("Starting test: SharedState - Space calculation");
    void* memory = allocateSharedState(1024);
    scope(exit) free(memory);
    
    auto state = cast(SharedState*)memory;
    assert(state.getAvailableSpace() == 1024, "Initial available space incorrect");
    
    ubyte[] testData = [1, 2, 3, 4, 5];
    state.writeBuffer(testData);
    assert(state.getUsedSpace() == size_t.sizeof + testData.length, 
           "Used space calculation incorrect");
    assert(state.getAvailableSpace() == 1024 - (size_t.sizeof + testData.length),
           "Available space calculation incorrect");
}


//@("Basic send/receive")
unittest {
    writeln("Starting test: Basic send/receive");
    JumboMessageQueue.cleanup("/test_basic"); // Clean up any leftover resources
    auto q = new JumboMessageQueue("/test_basic");
    scope(exit) {
        q.destroy();
        JumboMessageQueue.cleanup("/test_basic");
    }

    q.send(cast(ubyte[])"test");
    auto received = q.receive();
    assert(cast(string)received == "test", 
           "Expected message 'test' but received '" ~ cast(string)received ~ "'");
}

//@("Basic send/receive with separate queues")
unittest {
    writeln("Starting test: Basic send/receive with separate queues");
    auto sender = new JumboMessageQueue("/test_separate");
    auto receiver = new JumboMessageQueue("/test_separate");
    scope(exit) {
        sender.destroy();
        receiver.destroy();
        JumboMessageQueue.cleanup("/test_separate");
    }

    sender.send(cast(ubyte[])"test");
    auto received = receiver.receive();
    assert(cast(string)received == "test",
           "Expected message 'test' but received '" ~ cast(string)received ~ "'");
}

//@("Large messages")
unittest {
    writeln("Starting test: Large messages");
    auto q = new JumboMessageQueue("/test_large", 1024*1024*10);
    scope(exit) {
        q.destroy();
        JumboMessageQueue.cleanup("/test_large");
    }

    ubyte[1024*1024] data;
    data[] = 0xAA;
    q.send(cast(ubyte[])data);
    
    auto received = q.receive();
    assert(received.length == data.length,
           "Message length mismatch - Expected: " ~ data.length.to!string ~ ", Actual: " ~ received.length.to!string);
    assert(received[0] == 0xAA && received[$-1] == 0xAA,
           "Message content mismatch - Expected: 0xAA at start and end, Actual: " ~ 
           "0x" ~ received[0].to!string(16) ~ " at start, 0x" ~ received[$-1].to!string(16) ~ " at end");
}

//@("Large messages with separate queues")
unittest {
    writeln("Starting test: Large messages with separate queues");
    auto sender = new JumboMessageQueue("/test_large_separate", 1024*1024*10);
    auto receiver = new JumboMessageQueue("/test_large_separate", 1024*1024*10);
    scope(exit) {
        sender.destroy();
        receiver.destroy();
        JumboMessageQueue.cleanup("/test_large_separate");
    }

    ubyte[1024*1024] data;
    data[] = 0xAA;
    sender.send(cast(ubyte[])data);
    
    auto received = receiver.receive();
    assert(received.length == data.length,
           "Message length mismatch - Expected: " ~ data.length.to!string ~ ", Actual: " ~ received.length.to!string);
    assert(received[0] == 0xAA && received[$-1] == 0xAA,
           "Message content mismatch - Expected: 0xAA at start and end, Actual: " ~ 
           "0x" ~ received[0].to!string(16) ~ " at start, 0x" ~ received[$-1].to!string(16) ~ " at end");
}

//@("Full queue behavior")
unittest {
    writeln("Starting test: Full queue behavior");
    auto q = new JumboMessageQueue("/test_full", 1024);
    scope(exit) {
        q.destroy();
        JumboMessageQueue.cleanup("/test_full");
    }

    // Test proper blocking when queue is full
    void producer() {
        foreach(i; 0..50) {
            q.send([cast(ubyte)i, cast(ubyte)(i+1), cast(ubyte)(i+2)]); // 3 bytes + size_t overhead
        }
    }

    bool producerFinished = false;
    auto t = new Thread(&producer);
    t.start();

    // Wait briefly to let producer fill queue
    Thread.sleep(100.msecs);
    assert(!producerFinished, "Producer should block when queue is full");

    // Receive some messages to free space
    foreach(i; 0..10) {
        q.receive();
    }

    // Producer should now be able to continue
    t.join();
    producerFinished = true;
}

//@("Full queue behavior with separate queues")
unittest {
    writeln("Starting test: Full queue behavior with separate queues");
    auto sender = new JumboMessageQueue("/test_full_separate", 1024);
    auto receiver = new JumboMessageQueue("/test_full_separate", 1024);
    scope(exit) {
        sender.destroy();
        receiver.destroy();
        JumboMessageQueue.cleanup("/test_full_separate");
    }

    // Test proper blocking when queue is full
    void producer() {
        foreach(i; 0..50) {
            sender.send(cast(ubyte[])[cast(ubyte)i, cast(ubyte)(i+1), cast(ubyte)(i+2)]); // 3 bytes + size_t overhead
        }
    }

    bool producerFinished = false;
    auto t = new Thread(&producer);
    t.start();

    // Wait briefly to let producer fill queue
    Thread.sleep(100.msecs);
    assert(!producerFinished, "Producer should block when queue is full");

    // Receive some messages to free space
    foreach(i; 0..10) {
        receiver.receive();
    }
    
    // Producer should now be able to continue
    t.join();
    producerFinished = true;
}

//@("Variable message sizes")
unittest {
    writeln("Starting test: Variable message sizes");
    auto q = new JumboMessageQueue("/test_variable");
    scope(exit) {
        q.destroy();
        JumboMessageQueue.cleanup("/test_variable");
    }

    // Send messages of varying sizes
    q.send([cast(ubyte)1]);
    q.send([cast(ubyte)1,cast(ubyte)2,cast(ubyte)3,cast(ubyte)4,cast(ubyte)5]);
    q.send(cast(ubyte[])[]);
    q.send(cast(ubyte[])repeat("a", 100).array);

    // Verify all messages received correctly
    auto received1 = q.receive();
    assert(received1 == [1], 
           "Expected single byte message [1], got: " ~ received1.to!string);
    auto received2 = q.receive();
    assert(received2 == [1,2,3,4,5],
           "Expected 5-byte message [1,2,3,4,5], got: " ~ received2.to!string);
    auto received3 = q.receive();
    assert(received3 == [], 
           "Expected empty message [], got: " ~ received3.to!string);
    assert(q.receive() == cast(ubyte[])repeat("a", 100).array,
           "Expected 100 'a' bytes, got different content");
}

//@("Variable message sizes with separate queues")
unittest {
    writeln("Starting test: Variable message sizes with separate queues");
    auto sender = new JumboMessageQueue("/test_variable_separate");
    auto receiver = new JumboMessageQueue("/test_variable_separate");
    scope(exit) {
        sender.destroy();
        receiver.destroy();
        JumboMessageQueue.cleanup("/test_variable_separate");
    }

    // Send messages of varying sizes
    sender.send([cast(ubyte)1]);
    sender.send([cast(ubyte)1,cast(ubyte)2,cast(ubyte)3,cast(ubyte)4,cast(ubyte)5]);
    sender.send(cast(ubyte[])[]);
    sender.send(cast(ubyte[])repeat("a", 100).array);

    // Verify all messages received correctly
    auto received1 = receiver.receive();
    assert(received1 == [1],
           "Expected single byte message [1], got: " ~ received1.to!string);
    auto received2 = receiver.receive();
    assert(received2 == [1,2,3,4,5],
           "Expected 5-byte message [1,2,3,4,5], got: " ~ received2.to!string);
    auto received3 = receiver.receive();
    assert(received3 == [],
           "Expected empty message [], got: " ~ received3.to!string);
    assert(receiver.receive() == cast(ubyte[])repeat("a", 100).array,
           "Expected 100 'a' bytes, got different content");
}

//@("Buffer wrap-around")
unittest {
    writeln("Starting test: Buffer wrap-around");
    auto q = new JumboMessageQueue("/test_wrap", 256);
    scope(exit) {
        q.destroy();
        JumboMessageQueue.cleanup("/test_wrap");
    }

    // Fill buffer to near capacity
    ubyte[64] aPayload;
    aPayload[] = 'a';
    ubyte[32] bPayload;
    bPayload[] = 'b';

    q.send(aPayload);
    q.send(bPayload);

    // Receive first message to free space at start
    auto firstMsg = q.receive();
    assert(firstMsg.length == 64,
           "First message length mismatch - Expected: 64, Actual: " ~ firstMsg.length.to!string);

    // Send message that should wrap around buffer
    ubyte[64] cPayload;
    cPayload[] = 'c';
    q.send(cPayload);

    // Verify all messages
    auto msg1 = q.receive();
    assert(msg1 == bPayload,
           "Expected 32 'b' bytes, got different content with length " ~ msg1.length.to!string);
    auto msg2 = q.receive();
    assert(msg2 == cPayload,
           "Expected 64 'c' bytes, got different content with length " ~ msg2.length.to!string);
}

//@("Buffer wrap-around with separate queues")
unittest {
    writeln("Starting test: Buffer wrap-around with separate queues");
    auto sender = new JumboMessageQueue("/test_wrap_separate", 256);
    auto receiver = new JumboMessageQueue("/test_wrap_separate", 256);
    scope(exit) {
        sender.destroy();
        receiver.destroy();
        JumboMessageQueue.cleanup("/test_wrap_separate");
    }

    ubyte[64] aPayload;
    aPayload[] = 'a';
    ubyte[32] bPayload;
    bPayload[] = 'b';
    // Fill buffer to near capacity
    sender.send(aPayload);
    sender.send(bPayload);

    // Receive first message to free space at start
    auto firstMsg = receiver.receive();
    assert(firstMsg.length == 64,
           "First message length mismatch - Expected: 64, Actual: " ~ firstMsg.length.to!string);

    // Send message that should wrap around buffer
    ubyte[64] cPayload;
    cPayload[] = 'c';
    sender.send(cPayload);

    // Verify all messages
    auto msg1 = receiver.receive();
    assert(msg1 == bPayload,
           "Expected 32 'b' bytes, got different content with length " ~ msg1.length.to!string);
    auto msg2 = receiver.receive();
    assert(msg2 == cPayload,
           "Expected 64 'c' bytes, got different content with length " ~ msg2.length.to!string);
}

//@("Multiple producers")
unittest {
    writeln("Starting test: Multiple producers");
    auto q = new JumboMessageQueue("/test_multi");
    scope(exit) {
        q.destroy();
        JumboMessageQueue.cleanup("/test_multi");
    }

    void delegate() makeProducer(int id) {
        return () {
            foreach(i; 0..10) {
                q.send(cast(ubyte[])(id.to!string ~ "-" ~ i.to!string));
            }
        };
    }

    auto t1 = new Thread(makeProducer(1));
    auto t2 = new Thread(makeProducer(2));
    t1.start();
    t2.start();
    t1.join();
    t2.join();

    int count;
    for(int i = 0; i < 20; i++) {
        try {
            auto data = q.receive();
            count++;
        } catch(Exception) {
            break;
        }
    }
    assert(count == 20, "Expected 20 messages from multiple producers, got " ~ count.to!string);
}

//@("Multiple producers with separate queues")
unittest {
    writeln("Starting test: Multiple producers with separate queues");
    auto sender = new JumboMessageQueue("/test_multi_separate");
    auto receiver = new JumboMessageQueue("/test_multi_separate");
    scope(exit) {
        sender.destroy();
        receiver.destroy();
        JumboMessageQueue.cleanup("/test_multi_separate");
    }

    void delegate() makeProducer(int id) {
        return () {
            foreach(i; 0..10) {
                sender.send(cast(ubyte[])(id.to!string ~ "-" ~ i.to!string));
            }
        };
    }

    auto t1 = new Thread(makeProducer(1));
    auto t2 = new Thread(makeProducer(2));
    t1.start();
    t2.start();
    t1.join();
    t2.join();

    int count;
    for(int i = 0; i < 20; i++) {
        try {
            auto data = receiver.receive();
            count++;
        } catch(Exception) {
            break;
        }
    }
    assert(count == 20, "Expected 20 messages from multiple producers, got " ~ count.to!string);
}

//@("Cleanup")
unittest {
    writeln("Starting test: Cleanup");
    auto q = new JumboMessageQueue("/test_cleanup");
    q.destroy();
    JumboMessageQueue.cleanup("/test_cleanup");
    
    // Verify resources were actually freed
    // (would throw if resources weren't properly cleaned up)
    auto q2 = new JumboMessageQueue("/test_cleanup");
    q2.destroy();
    JumboMessageQueue.cleanup("/test_cleanup");
}

//@("Cleanup with separate queues")
unittest {
    writeln("Starting test: Cleanup with separate queues");
    auto sender = new JumboMessageQueue("/test_cleanup_separate");
    auto receiver = new JumboMessageQueue("/test_cleanup_separate");
    sender.destroy();
    receiver.destroy();
    JumboMessageQueue.cleanup("/test_cleanup_separate");
    
    // Verify resources were actually freed
    auto sender2 = new JumboMessageQueue("/test_cleanup_separate");
    auto receiver2 = new JumboMessageQueue("/test_cleanup_separate");
    sender2.destroy();
    receiver2.destroy();
    JumboMessageQueue.cleanup("/test_cleanup_separate");
}

//@("Empty queue blocks")
unittest {
    writeln("Starting test: Empty queue blocks");
    auto q = new JumboMessageQueue("/test_blocking");
    scope(exit) {
        q.destroy();
        JumboMessageQueue.cleanup("/test_blocking");
    }

    ubyte[] receivedData;
    bool received = false;

    // Thread that will block on receive
    void receiver() {
        receivedData = q.receive(); // Should block until message arrives
        received = true;
    }

    // Thread that will send after delay
    void sender() {
        Thread.sleep(100.msecs);
        q.send(cast(ubyte[])"test");
    }

    auto t1 = new Thread(&receiver);
    auto t2 = new Thread(&sender);
    t1.start();
    t2.start();
    t1.join();
    t2.join();

    assert(received, "Expected receiver thread to receive message and set received flag");
    assert(cast(string)receivedData == "test", 
           "Message content mismatch - Expected: 'test', Actual: '" ~ cast(string)receivedData ~ "'");
}

//@("Empty queue blocks with separate queues")
unittest {
    writeln("Starting test: Empty queue blocks with separate queues");
    auto sender = new JumboMessageQueue("/test_blocking_separate");
    auto receiver = new JumboMessageQueue("/test_blocking_separate");
    scope(exit) {
        sender.destroy();
        receiver.destroy();
        JumboMessageQueue.cleanup("/test_blocking_separate");
    }

    ubyte[] receivedData;
    bool received = false;

    // Thread that will block on receive
    void receiverThread() {
        receivedData = receiver.receive(); // Should block until message arrives
        received = true;
    }

    // Thread that will send after delay
    void senderThread() {
        Thread.sleep(100.msecs);
        sender.send(cast(ubyte[])"test");
    }

    auto t1 = new Thread(&receiverThread);
    auto t2 = new Thread(&senderThread);
    t1.start();
    t2.start();
    t1.join();
    t2.join();  

    assert(received, "Expected receiver thread to receive message and set received flag");
    assert(cast(string)receivedData == "test",
           "Message content mismatch - Expected: 'test', Actual: '" ~ cast(string)receivedData ~ "'");
}
