defmodule STC do
  @moduledoc """
  A generic scheduler for all operations on strong compute

  Takes a task template and schedules it on some resources (agents)

  Its capable of restarting failed tasks, retrying tasks, and handling task dependencies - a directed graph of tasks to complete in a workflow

  Eg
  - scheduling a cycle experiment - uniquely requires a bunch of agents - runs them one to one
  - scheduling io work for experiments - selects io agents on load and runs a sync task
  - syncing data and containers at the start of an experiment - each step is a task - but running an experiment requires all tasks to be completed

  Tasks have a state -

  The scheduler also state saves so it can be interrupted and restarted

  Tasks have a retry policy
  Tasks have a timeout policy
  Tasks can have dependencies
  Tasks have affinity constraints (exclusive (only one task on this agent), shared (multiple tasks on this agent))
  Tasks have a requirement of a certain type of agent (cycle, io, workstation)
  Tasks can be scheduled on multiple agents (1 to many)

  Tasks initiate billing events (start / stop a task = start / stop billing)

  Tasks run on agents - on a single cluster

  There are several levels of scheduling

  across some agents

  within a space

  across multiple spaces

  across multiple clusters /

  workflows are a series of tasks - so workflows exist across clusters

  there are different scheduling algorithms
  """
end
