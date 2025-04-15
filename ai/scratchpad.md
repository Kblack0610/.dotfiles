# Autoclicker Improvement Scratchpad

## Current Issues

### 1. Cursor Movement Interference
The autoclicker tool currently moves the actual cursor, which can interfere with normal computer usage while it's running.

### 2. Code Structure
The current implementation could benefit from a more modular design and automated tests.

## Proposed Solutions

### Multiple Cursor Approach Using xinput

Linux's xinput utility could be used to create and manage virtual input devices, allowing for:

- Creation of a secondary cursor that doesn't interfere with the main cursor
- Separation of automation actions from user inputs

#### Implementation Ideas:

```bash
# Create a virtual pointer device
VIRTUAL_DEVICE=$(xinput create-master "Virtual Pointer")

# Get the ID of the new pointer
POINTER_ID=$(xinput list | grep "Virtual Pointer" | grep -oP "id=\K\d+")

# Send events to the virtual pointer
xinput set-ptr-feedback $POINTER_ID 0 0 0
xinput --test-xi2 $POINTER_ID  # Monitor events

# Move the virtual pointer
# This would require writing to the virtual device using low-level X11 APIs
```

Challenges:
- Requires root permissions or special udev rules
- Need to map window coordinates correctly
- May require substantial reworking of the X11 interaction code

### Modular Design Improvements

#### Proposed Module Structure:

1. **Core Modules**
   - `input_manager.py`: Handle all input operations (clicks, typing)
   - `window_manager.py`: Handle window detection and focusing
   - `image_processor.py`: Handle screenshot capture and image recognition
   - `action_controller.py`: Orchestrate the execution of automation sequences

2. **UI Layer**
   - `cli.py`: Command line interface
   - `config_manager.py`: Configuration loading/saving

3. **Test Structure**
   - Unit tests for each module
   - Integration tests for common workflows
   - Mock objects for X11 display to enable testing without actual GUI

## Next Steps

1. Research xinput approach in detail:
   - Test creating virtual input devices
   - Determine if permissions can be handled gracefully
   - Experiment with sending events to specific windows

2. Create a design document for the modular refactoring:
   - Define clear interfaces between modules
   - Identify boundaries and responsibilities

3. Set up a testing framework:
   - Create mock objects for X11 interactions
   - Write initial tests for core functionality
   - Implement CI workflow for automated testing

## Resources

- [xinput documentation](https://www.x.org/archive/X11R7.5/doc/man/man1/xinput.1.html)
- [Python X11 libraries](https://github.com/python-xlib/python-xlib)
- [Python testing frameworks](https://docs.pytest.org/)
