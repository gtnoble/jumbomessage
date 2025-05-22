# JumboMessage

A high-performance shared memory queue system for D, designed for efficient inter-process communication through POSIX shared memory.

## Features

- Fast inter-process communication using POSIX shared memory
- Thread-safe operations with semaphore synchronization
- Support for large messages with configurable buffer size
- Automatic resource cleanup and proper memory management
- Binary data support for versatile message types
- Built-in flow control for producers and consumers
- Circular buffer implementation for efficient memory usage

## Requirements

- D compiler (DMD, LDC, or GDC)
- POSIX-compliant operating system (Linux, macOS, etc.)
- POSIX shared memory and semaphore support

## Installation

Add JumboMessage as a dependency in your `dub.json`:

```json
{
    "dependencies": {
        "jumbomessage": "~>1.0.0"
    }
}
```

Or clone the repository and include the source directly in your project:

```bash
git clone https://github.com/yourusername/jumbomessage.git
```

## Usage

### Creating a Queue

```d
import jumbomessage;

// Create a queue with default size (1MB)
auto queue = new JumboMessageQueue("/myqueue");

// Or specify a custom size (e.g., 10MB)
auto largeQueue = new JumboMessageQueue("/myqueue", 1024*1024*10);
```

### Sending Messages

```d
// Send text messages
queue.send(cast(ubyte[])"Hello World");

// Send binary data
ubyte[] data = [1, 2, 3, 4, 5];
queue.send(data);
```

### Receiving Messages

```d
// Receive data from queue
ubyte[] data = queue.receive();

// Convert to string if needed
string text = cast(string)data;
```

### Cleanup

```d
// Clean up queue resources
JumboMessageQueue.cleanup("/myqueue");
```

## Example Programs

The project includes example producer and consumer programs demonstrating queue usage:

### Producer Example

```d
// examples/producer.d
void main() {
    auto queue = new JumboMessageQueue("/example_queue", 1024*1024*10);
    
    foreach (i; 0..5) {
        string msg = "Message " ~ to!string(i);
        queue.send(cast(ubyte[])msg);
    }
}
```

### Consumer Example

```d
// examples/consumer.d
void main() {
    auto queue = new JumboMessageQueue("/example_queue");
    
    while (true) {
        auto data = queue.receive();
        writeln("Received: ", cast(string)data);
    }
}
```

To run the examples:

1. Compile and run the consumer in one terminal:
```bash
dmd -run examples/consumer.d source/jumbomessage.d
```

2. Compile and run the producer in another terminal:
```bash
dmd -run examples/producer.d source/jumbomessage.d
```

## API Documentation

### JumboMessageQueue

The main class for queue operations:

#### Constructor
```d
this(string queueName, size_t size = 1024 * 1024)
```
- `queueName`: Unique identifier for the queue
- `size`: Buffer size in bytes (default: 1MB)

#### Methods

- `void send(const ubyte[] data)`: Send data to the queue
- `ubyte[] receive()`: Receive data from the queue
- `void clear()`: Clear all data from the queue
- `static void cleanup(string queueName)`: Clean up queue resources

#### Properties

- `string name()`: Get queue name
- `int spaceAvailableValue()`: Get available space semaphore value
- `int dataAvailableValue()`: Get available data semaphore value

## Implementation Details

JumboMessage uses a circular buffer implementation with:
- POSIX shared memory for data storage
- Semaphores for synchronization
- Binary data support
- Automatic resource management

The implementation ensures:
- Thread-safe operations
- Proper cleanup of system resources
- Efficient memory usage
- Flow control between producers and consumers

## Error Handling

The system includes various safety checks:
- Buffer overflow protection
- Resource allocation verification
- Semaphore initialization validation
- Proper error messaging for debugging

## License

[Add your chosen license here]
