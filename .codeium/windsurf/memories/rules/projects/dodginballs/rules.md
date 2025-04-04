# Git worktree 
- Use git worktree to build out features.
- For using git worktree, 
- you should create a worktree off the current branch to not disrupt my current work
- After feature is completed, merge your changes into a new branch on worktree that I'm working on. DO NOT CHECK IT OUT, that will disrupt the work I'm doing.
- delete created worktree.
- keep worktrees clean. There should only be two worktrees at most, the main one I'm working on and the worktree that you're working on.

# Unity
<!-- - verify that unitymcp is working fully before starting. -->
<!-- - if unitymcp is not working, then do not ship anything that has broken unity compiler errors. -->
<!-- - stop working until unitymcp is working fully. -->

- use unity compiler to check for errors if available
- use unity mcp to validate code and fix any errors.
- make sure to use unity mcp to validate code and fix any errors.
- here's specific unity mcp commands you recommended to use:

- If I start prompt with *CURRENT*, then do not make the changes on a new worktree and just make them locally instead.
 
<!-- mcp2_get_scene_info - to get info about the current scene -->
<!-- mcp2_open_scene - to open a scene for testing -->
<!-- mcp2_create_object - to create test objects -->
<!-- mcp2_view_script - to view scripts -->
<!-- mcp2_get_hierarchy - to see the hierarchy -->
<!-- mcp2_read_console - to check for errors -->

- do no ship anything that has broken unity compiler errors.

# Testing
https://docs.unity3d.com/Manual/testing-editortestsrunner.html
- use unity testing framework to test your code.
