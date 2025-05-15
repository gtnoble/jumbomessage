module consumer;

import jumbomessage;
import std.stdio;
import std.conv;

void main() {
    auto queue = new JumboMessageQueue("/example_queue");
    
    while (true) {
        try {
            auto data = queue.receive();
            if (data.length <= 100) {
                writeln("Received: ", cast(string)data);
            } else {
                writeln("Received large message of size: ", data.length);
            }
        } catch (Exception e) {
            writeln("Queue error: ", e.msg);
            break;
        }
    }
}
