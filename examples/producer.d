module producer;

import jumbomessage;
import std.stdio;
import std.conv;

void main() {
    auto queue = new JumboMessageQueue("/example_queue", 1024*1024*10); // 10MB
    
    foreach (i; 0..5) {
        string msg = "Message " ~ to!string(i);
        writeln("Sending: ", msg);
        queue.send(cast(ubyte[])msg);
    }
    
    ubyte[1024*1024] largeData;
    largeData[] = 0xAA;
    queue.send(largeData);
    
    writeln("Producer done");
}
