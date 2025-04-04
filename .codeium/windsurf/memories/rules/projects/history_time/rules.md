-# Core System Components
- The main application logic is in src/core.
- Shared utilities and helpers are in src/utils.
- Feature flags and configuration settings are in src/config.

# Backend Code Structure
- Backend logic is in server
- All API request handlers for Cascade are in server/api.
- Task execution queue is managed in server/tasks/queue.py.

# Frontend Code Structure
- The UI components for the assistant are in frontend/components/assistant.
- The AI command panel logic is handled in frontend/components/command_panel.tsx.
- Styles for the AI interface are in frontend/styles/assistant.css.

# Data & Storage
- Vector embeddings are stored in server/data/vector_store.
- User session history is saved in server/data/sessions.
- Logs and analytics are collected in server/logs/usage_tracking.log.

# Testing & Debugging
- End-to-end tests for Cascade are in tests/e2e/tests.
- Mock API responses for local testing are in tests/mocks/api_mocks.py.
- Debugging scripts are located in scripts/debugging_tools.
