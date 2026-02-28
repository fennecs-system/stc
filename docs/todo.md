## todos

- cancel / stop - stop a task mid execution

- can continue logic in scheduler - for example checking the budget, checking the memory  etc. Can this task in this workflow continue or do we need to pause it, cancel it etc

- move task execution - eg a node dies in this space - lets move it, or gets requested to move

- run a task for x time

- task dependency splicing? suppose workflow A and workflow B have a task that downloads something X. Suppose A is downloading X currently - then B needs to add it as a dependency and somehow splice in that requirement. Perhaps theres a /hash/ of tasks or something? it would be the exact same task even if its part of different workflows. get tasks by hash?

- tracing back cleanup - eg suppose the workflow is download => start container => stop => start => delete. We can walk back all the .clean steps on each task.

- who initiates cleanup tasks? lookup via horde - cancel it.