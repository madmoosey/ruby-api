# Content Idea API (Ruby)

A small Ruby API backed by PostgreSQL that generates and refines content ideas with OpenAI.

This version uses:

- Sinatra for the HTTP API
- Sequel for PostgreSQL access
- the `openai` Ruby SDK for idea generation and refinement

## Features

- create a new idea set for a topic
- list all saved idea sets
- fetch a single idea set by `idea_id`
- refine an existing idea set in place using `idea