# 1. StruoDB Architecture — Overview

A distributed StruoDB deployment consists of interconnected nodes 
filling three distinct roles:
* **Event Collector**
* **Event Aggregator**
* **Event Projector**

Here is a simple example:
![StruoDB Node Roles](/images/StruoDB-Architecture.drawio.png)

Events are created within event collectors, flow to event aggregators, 
and are transformed within event projectors.

Event collectors and event aggregators maintain **streams** of events.
Event projectors maintain **derived streams** and **projections** of events.