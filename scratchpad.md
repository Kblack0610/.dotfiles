# Lessons

- For website image paths, always use the correct relative path (e.g., 'images/filename.png') and ensure the images directory exists
- For search results, ensure proper handling of different character encodings (UTF-8) for international queries
- Add debug information to stderr while keeping the main output clean in stdout for better pipeline integration
- When using seaborn styles in matplotlib, use 'seaborn-v0_8' instead of 'seaborn' as the style name due to recent seaborn version changes
- When using Jest, a test suite can fail even if all individual tests pass, typically due to issues in suite-level setup code or lifecycle hooks
- When using Python MCP with filesystem operations, be aware of permission issues - prefer using tempfile module for safe file operations
- When using MCPs with Claude Assistant, note that direct MCP commands are not recognized - they must be properly integrated through the tool system

## Windsurf learned

- For search results, ensure proper handling of different character encodings (UTF-8) for international queries
- Add debug information to stderr while keeping the main output clean in stdout for better pipeline integration
- When using seaborn styles in matplotlib, use 'seaborn-v0_8' instead of 'seaborn' as the style name due to recent seaborn version changes
- Use 'gpt-4o' as the model name for OpenAI's GPT-4 with vision capabilities 

# Scratchpad

## Current Focus: End-to-End Integration Testing of Claude Assistant with New MCPs

### Overview
We need to perform thorough end-to-end regression testing of the Claude Assistant application to ensure it correctly integrates with our newly added MCPs. The focus is on verifying that the application's core functionality works seamlessly with these new capabilities, and identifying any integration gaps.

### Testing Results

#### 1. Core Claude Assistant Functionality with New MCPs
- [X] Command-line interface functionality
  - [X] All commands work with basic MCP integrations - PASS (validate_quick.sh passes)
  - [X] Help text includes core-only mode option - PASS
  - [ ] Help text doesn't explicitly mention new MCPs - ISSUE

- [ ] Conversation and context management
  - [ ] Conversation history seems to work with new MCPs - PARTIAL
  - [ ] Context window handling needs more testing - NOT TESTED
  - [ ] Memory management with MCP results - NOT TESTED

- [ ] Rules and system prompts
  - [ ] System prompts need updates for new MCP capabilities - ISSUE
  - [ ] Rules system doesn't explicitly mention MCPs - ISSUE
  - [ ] Custom rules for MCP behaviors - NOT TESTED

#### 2. Claude Assistant Tool Integration
- [X] Filesystem operations
  - [✓] MCP Filesystem functions work properly in direct testing - PASS
  - [X] Claude Assistant doesn't directly recognize filesystem MCP commands - ISSUE
  - [X] Code intelligence features provide filesystem access but not through MCPs - PARTIAL

- [X] Python execution
  - [✓] Python MCP works for code execution in direct testing - PASS
  - [X] Claude provides Python code but doesn't execute it directly - ISSUE
  - [X] Integration between Python MCP and Assistant not complete - ISSUE

- [ ] GitHub integration
  - [ ] Repository operations - NOT TESTED
  - [ ] Issue management - NOT TESTED
  - [ ] Code review - NOT TESTED

- [X] AI capabilities
  - [X] Web search - NOT RECOGNIZED BY CLAUDE
  - [X] Sequential thinking - NOT RECOGNIZED BY CLAUDE
  - [X] Tool-using chains - PARTIAL INTEGRATION

#### 3. Runtime Configurations
- [X] Core-only mode
  - [X] Minimal functionality works - PASS
  - [X] Validation tests pass - PASS
  - [ ] Integration with new MCPs - NOT TESTED

- [X] Full mode
  - [X] Basic functionality works - PASS
  - [X] Validation tests pass - PASS
  - [X] MCP integration incomplete - ISSUE

- [X] Headless operation
  - [X] Scripts run properly - PASS
  - [X] Output formatting works - PASS
  - [X] MCP integration incomplete - ISSUE

#### 4. Cross-functional Workflows
- [X] All cross-functional workflows - NOT FUNCTIONING WITH MCPs

### Regression Test Cases
- [X] All previous commands and functionality still work - PASS
- [X] Performance appears acceptable - PASS
- [X] Memory usage appears normal - PASS
- [ ] Error handling with MCP failures - NOT TESTED
- [X] Output formatting consistent - PASS

### Identified Gaps and Needed Enhancements

1. **System Integration Issues**:
   - Claude Assistant doesn't recognize direct MCP commands
   - Need to update system prompts to include MCP capabilities
   - Need explicit instructions for Claude on how to use MCPs

2. **Claude Prompt Updates**:
   - Claude needs explicit examples of MCP usage in prompts
   - Tool definitions should include MCP capabilities
   - System prompts need to be updated to explain MCP functionality

3. **Documentation and Help Text**:
   - Help text should include information about available MCPs
   - Documentation for MCP capabilities should be improved
   - Examples of MCP usage should be provided

4. **Tooling Integration**:
   - Need better integration between Claude Assistant tooling system and MCPs
   - Tool registry should properly expose MCP capabilities
   - Tool calling mechanism needs updates to properly handle MCPs

### Next Steps
1. Update system prompts to include explicit MCP instructions
2. Enhance tool definitions to expose MCP capabilities
3. Update help documentation to include MCP information
4. Create examples of correct MCP usage for Claude
5. Update validation tests to check MCP integration