fetchIO
=======

[fetchIO](https://github.com/gip/fetchio) is a simple, configurable, fault-tolerant http crawler written in Haskell. 

The main features are:

* Configurable number of concurrent fetcher pipelines
* Reuse of http connection (configurable)
* fetched HTML is zipped and binary64-encoded
* Configurable using a simple JSON file

History
-------

The previous version of this tool, [fureteur](https://github.com/gip/fureteur), was written in Scala. The scalability quickly became an issue however, not to mention the high load on the machine. The use of Scala actors provided a very nice abstraction during the implementation of [fureteur](https://github.com/gip/fureteur). However reaching high-performance with acceptable hardware quickly became an issue.

[fetchIO](https://github.com/gip/fetchio) uses Haskell lightweight threads. Refer to [this book](http://book.realworldhaskell.org/read/concurrent-and-multicore-programming.html) for more information regarding Haskell forkIO and concurrent programming. While very simple, [fetchIO](https://github.com/gip/fetchio) is able to reach very high performance on commoditized servers.


Distributed Crawling
--------------------

Fureteur makes it very easy to implement a distributed crawler - for instance on [Amazon AWS EC2](http://aws.amazon.com/ec2/). 

![Example of distributed crawler on EC2](https://github.com/gip/fureteur/raw/master/doc/dcrawling.jpg)

The main server above includes RabbitMQ queues storing the URLs to be fetched (fetchIn queues) and a queue that includes the fetched data. A simple JSON format is used for the messages. Separate tasks running on the server take care of scheduling URLs to be fetched and writing back the data into a distributed database. 

A configurable number of fetcher can be started using separate EC2 instances. Each instance will get URLs batches from the server fetchIn queues, fetch them and write them back into the fetchOut queue. Cost-effective EC2 micro instances may be used since fetching is not a CPU-intensive task. When it comes to the fetcher instances, the system is totally fault-tolerant - if an instance becomes unresponsive and/or is abruptly terminated, no data will be lost thanks to the RabbitMQ acknowledgement mechanism.

Getting Started
---------------

TBD


Contact
-------

Created by [Gilles Pirio](https://github.com/gip). Feel free to contact me at [gip.github@gmail.com](mailto:gip.github@gmail.com). 
