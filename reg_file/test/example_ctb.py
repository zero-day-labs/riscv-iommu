# Copyright © 2023 Manuel Rodríguez & Zero-Day Labs, Lda.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Author:   Manuel Rodríguez <manuel.cederog@gmail.com>
# Date:     12/10/2022
#
# Description:  Test example using cocotb

import cocotb
from cocotb.triggers import FallingEdge, Timer
from cocotb.clock import Clock

# Async reset generation function
async def reset_dut(reset_n, duration_ns):
    reset_n.value = 0
    await Timer(duration_ns, units="ns")
    reset_n.value = 1
    reset_n._log.debug("Reset complete")

# Asynchronous clock generation function.
# Should be called with cocotb.start method in the test, in order to run in the background
async def generate_clock(dut):
    """Generate clock pulses."""

    for cycle in range(10):
        dut.clk.value = 0
        await Timer(1, units="ns")
        dut.clk.value = 1
        await Timer(1, units="ns")


@cocotb.test()  # decorator to mark the test function to be run
async def my_second_test(dut):
    """Try accessing the design."""

    ''' ===================================== Basic example ====================================== '''
    # await cocotb.start(generate_clock(dut))  # manual manner to run the clock "in the background"
    cocotb.start_soon(Clock(dut.clk, 1, units="ns").start())    # cocotb built-in helper for clock generation

    await Timer(5, units="ns")  # wait a bit
    await FallingEdge(dut.clk)  # wait for falling edge/"negedge"

    dut._log.info("my_signal_1 is %s", dut.my_signal_1.value)
    assert dut.my_signal_2.value[0] == 0, "my_signal_2[0] is not 0!"


    ''' ===================================== Assignments ====================================== '''
    # <sig.value = new_value> has the same semantic as HDL procedural (synchronous) assignments
    # <sig.setimmediatevalue(new_val)> acts like continuous (immediate) assignments

    # Get a reference to the "clk" signal and assign a value
    clk = dut.clk
    clk.value = 1

    # Direct assignment through the hierarchy
    dut.input_signal.value = 12

    # Assign a value to a memory deep in the hierarchy
    dut.sub_block.memory.array[4].value = 2

    ''' ===================================== Signed and Unsigned values ====================================== '''
    # Cocotb only considers the width of the signal. The sign definition is problem of the SV code
    # Cocotb allows any value in the range from the minimum negative value for a signed number, up to the
    #   max positive number for an unsigned value.

    ''' ===================================== Concurrent and sequential execution ====================================== '''
    # the <await> call runs an async coroutine and blocks the caller coroutine until this returns
    # <start> and <start_soon> runs the coroutine concurrently, so the caller routine will continue executing

    # Run reset_dut concurrently
    reset_thread = cocotb.start_soon(reset_dut(reset_n, duration_ns=500))   

    # This timer will complete before the timer in the concurrently executing "reset_thread"
    await Timer(250, units="ns")
    dut._log.debug("During reset (reset_n = %s)" % reset_n.value)

    # Wait for the background reset thread to complete
    await reset_thread
    dut._log.debug("After reset")

    ''' ===================================== Forcing and freezign signals ==================================== '''
    # Force makes a signal hold a value until it is released. Freeze forces the signal to hold its current value until released
    # Deposit action
    dut.my_signal.value = 12
    dut.my_signal.value = Deposit(12)  # equivalent syntax

    # Force action
    dut.my_signal.value = Force(12)    # my_signal stays 12 until released

    # Release action
    dut.my_signal.value = Release()    # Reverts any force/freeze assignments

    # Freeze action
    dut.my_signal.value = Freeze()     # my_signal stays at current value until released

    ''' ===================================== Passing and failing tests ==================================== '''
    # A cocotb test is considered to have failed if it fails an assert statement.
    # Erroring is when a test raises an exception related to its design (e.g. reference to a signal/coro that does not exists)
    # A test that does not error or fail, is considered to have passed

    ''' ===================================== Logging ==================================== '''
    # Each forked coroutine, the DUT, or any hierarchical object can have its own logging level
    task = cocotb.start_soon(coro)
    task.log.setLevel(logging.DEBUG)
    task.log.debug("Running Task!")

    dut.my_signal._log.info("Setting signal")
    dut.my_signal.value = 1


    ''' ===================================== Tasks and Coroutines (Blocking execution) ==================================== '''
    # The await keyword is used to pass execution from the simulator to a coroutine, and wait for it to complete
    # Coroutines started with the await keyword can return values

    async def get_signal(clk, signal):
        await RisingEdge(clk)
        return signal.value

    async def check_signal_changes(dut):
        first = await get_signal(dut.clk, dut.signal)   # block execution until a rising edge of the clock
        second = await get_signal(dut.clk, dut.signal)  # block again 
        assert first != second, "Signal did not change"

    ''' ===================================== Concurrent execution ==================================== '''
    # Coroutines may be scheduled with start() and start_soon() calls
    # start() yields control to the new task before the calling coroutine continues execution
    # start_soon() schedules the new coroutine for future execution, after the calling task

    @cocotb.test()
    async def test_act_during_reset(dut):
        """While reset is active, toggle signals"""
        tb = uart_tb(dut)
        # "Clock" is a built in class for toggling a clock signal
        cocotb.start_soon(Clock(dut.clk, 1, units='ns').start())
        # reset_dut is a function -
        # part of the user-generated "uart_tb" class
        # run reset_dut immediately before continuing
        await cocotb.start(tb.reset_dut(dut.rstn, 20))

        await Timer(10, units='ns')
        print("Reset is still active: %d" % dut.rstn)
        await Timer(15, units='ns')
        print("Reset has gone inactive: %d" % dut.rstn)

    # A background task can be killed before completing
    @cocotb.test()
    async def test_different_clocks(dut):
        clk_1mhz   = Clock(dut.clk, 1.0, units='us')
        clk_250mhz = Clock(dut.clk, 4.0, units='ns')

        clk_gen = cocotb.start_soon(clk_1mhz.start())
        start_time_ns = get_sim_time(units='ns')
        await Timer(1, units='ns')
        await RisingEdge(dut.clk)
        edge_time_ns = get_sim_time(units='ns')
        if not isclose(edge_time_ns, start_time_ns + 1000.0):
            raise TestFailure("Expected a period of 1 us")

        clk_gen.kill()  # kill clock coroutine here

    ''' ===================================== Triggers ==================================== '''
    # Used to indicate the cocotb scheduler that the await condition has ended
    # Examples:

    t1 = Timer(10, units='ps')
    t2 = Timer(10, units='ps')
    t_ret = await First(t1, t2)

    forked = cocotb.start_soon(mycoro())
    result = await Join(forked)

    
