`timescale 1ns/1ns

// Compute Core module: Executes instructions for a block of threads in SIMD fashion
// Manages a block of threads, each with dedicated registers, ALU, and LSU
// Uses THREADS_PER_BLOCK for generate loop, with active_threads as runtime mask
module compute_core #(
    parameter DATA_MEM_ADDR_BITS = 8,        // Data memory address width (256 rows)
    parameter DATA_MEM_DATA_BITS = 8,        // Data memory data width (8-bit data)
    parameter PROGRAM_MEM_ADDR_BITS = 8,     // Program memory address width (256 rows)
    parameter PROGRAM_MEM_DATA_BITS = 16,    // Program memory data width (16-bit instructions)
    parameter THREADS_PER_BLOCK = 4          // Number of threads per block
) (
    input clk,                          // Clock signal
    input reset,                        // Reset signal
    input logic start,                        // Start signal to begin execution
    output logic done,                         // Done signal when execution completes
    input logic [7:0] block_id,               // Block ID for this core
    input logic [$clog2(THREADS_PER_BLOCK):0] thread_count, // Number of active threads
    output logic program_mem_read_valid,       // Program memory read request
    output logic [PROGRAM_MEM_ADDR_BITS-1:0] program_mem_read_address, // Program memory address
    input logic program_mem_read_ready,       // Program memory ready signal
    input logic [PROGRAM_MEM_DATA_BITS-1:0] program_mem_read_data,    // Program memory data
    output logic [THREADS_PER_BLOCK-1:0] data_mem_read_valid,          // Data memory read requests

    output logic [THREADS_PER_BLOCK-1:0][DATA_MEM_ADDR_BITS-1:0] data_mem_read_address, // Data memory read addresses
    input logic [THREADS_PER_BLOCK-1:0] data_mem_read_ready,          // Data memory read ready signals
    input logic [THREADS_PER_BLOCK-1:0][DATA_MEM_DATA_BITS-1:0] data_mem_read_data,   // Data memory read data
    output logic [THREADS_PER_BLOCK-1:0] data_mem_write_valid,         // Data memory write requests
    output logic [THREADS_PER_BLOCK-1:0][DATA_MEM_ADDR_BITS-1:0] data_mem_write_address, // Data memory write addresses
    output logic [THREADS_PER_BLOCK-1:0][DATA_MEM_DATA_BITS-1:0] data_mem_write_data,   // Data memory write data    
    input logic [THREADS_PER_BLOCK-1:0] data_mem_write_ready          // Data memory write ready signals
);

    // Internal signals
    logic [PROGRAM_MEM_ADDR_BITS-1:0] PC;     // Program counter
    logic [15:0] instruction;                 // Current instruction
    logic [3:0] opcode;                       // Opcode from instruction
    logic [3:0] Rd, Rs, Rt;                   // Register fields
    logic [7:0] IMM8;                         // Immediate value
    logic [3:0] condition;                    // Condition codes for BRNzp
    logic is_nop, is_branch, is_cmp, is_add, is_sub, is_mul, is_div, is_ldr, is_str, is_const, is_halt; // Control signals
    logic [THREADS_PER_BLOCK-1:0][7:0] reg_data1; // First operand data
    logic [THREADS_PER_BLOCK-1:0][7:0] reg_data2; // Second operand data
    logic [THREADS_PER_BLOCK-1:0][7:0] write_data; // Data to write to registers
    logic [THREADS_PER_BLOCK-1:0] write_enable;     // Register write enables
    logic [3:0] write_addr;                         // Register write address
    logic [THREADS_PER_BLOCK-1:0][7:0] alu_result; // ALU results
    logic [THREADS_PER_BLOCK-1:0][2:0] NZP;        // Per-thread NZP flags
    logic [THREADS_PER_BLOCK-1:0] active_threads;   // Active thread mask
    logic fetch_enable;                             // Enable fetch unit
    logic fetch_done;                               // Fetch completion signal
    logic load_pc;                                  // Load new PC value
    logic [PROGRAM_MEM_ADDR_BITS-1:0] next_pc;      // Next PC value
    logic [THREADS_PER_BLOCK-1:0] lsu_done;         // LSU completion signals
    logic [THREADS_PER_BLOCK-1:0][7:0] lsu_load_data; // Separate signal for LSU output to avoid multi-driver

    // State machine for core execution
    core_state_t core_state;

    // State machine logic
    always_ff @(posedge clk or negedge reset) begin
        if (~reset) begin
            core_state <= IDLE;
            done <= 0;
            fetch_enable <= 0;
        end else begin
            case (core_state)
                IDLE: begin
                    if (start) begin
                        core_state <= FETCH;
                        fetch_enable <= 1;
                        done <= 0;
                    end
                end
                FETCH: begin
                    if (fetch_done) begin
                        core_state <= DECODE;
                        fetch_enable <= 0;
                    end
                end
                DECODE: begin
                    core_state <= EXECUTE;
                end
                EXECUTE: begin
                    if (&lsu_done || !(is_ldr || is_str)) begin  // Wait for LSUs if memory op
                        core_state <= WRITEBACK;
                    end
                end
                WRITEBACK: begin
                    if (is_halt) begin
                        core_state <= HALT;
                    end else begin
                        core_state <= FETCH;
                        fetch_enable <= 1;
                    end
                end
                HALT: begin
                    done <= 1;
                    core_state <= IDLE;
                end
                default: core_state <= IDLE;
            endcase
        end
    end

    // Submodule instances
    fetch #(.PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS), .PROGRAM_MEM_DATA_BITS(PROGRAM_MEM_DATA_BITS)) fetch_inst (
        .clk(clk),
        .reset(reset),
        .enable(fetch_enable),
        .PC(PC),
        .program_mem_read_valid(program_mem_read_valid),
        .program_mem_read_address(program_mem_read_address),
        .program_mem_read_ready(program_mem_read_ready),
        .program_mem_read_data(program_mem_read_data),
        .instruction(instruction),
        .fetch_done(fetch_done)
    );

    decoder decoder_inst (
        .instruction(instruction),
        .opcode(opcode),
        .Rd(Rd),
        .Rs(Rs),
        .Rt(Rt),
        .IMM8(IMM8),
        .condition(condition),
        .is_nop(is_nop),
        .is_branch(is_branch),
        .is_cmp(is_cmp),
        .is_add(is_add),
        .is_sub(is_sub),
        .is_mul(is_mul),
        .is_div(is_div),
        .is_ldr(is_ldr),
        .is_str(is_str),
        .is_const(is_const),
        .is_halt(is_halt)
    );

    scheduler #(.THREADS_PER_BLOCK(THREADS_PER_BLOCK),
	        .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS))
    scheduler_inst (
        .clk(clk),
        .reset(reset),
        .thread_count(thread_count),
        .is_branch(is_branch),
        .condition(condition[2:0]),
        .IMM8(IMM8),
        .PC(PC),
        .NZP(NZP),
        .core_state(core_state),
        .active_threads(active_threads),
        .next_pc(next_pc),
        .load_pc(load_pc)
    );

    program_counter #(.PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS)) pc_inst (
        .clk(clk),
        .reset(reset),
        .load(load_pc),
        .next_pc(next_pc),
        .PC(PC)
    );

    // Per-thread instances for registers, ALU, and LSU
    generate
        for (genvar t = 0; t < THREADS_PER_BLOCK; t = t + 1) begin : threads
            registers registers_inst (
                .clk(clk),
                .reset(reset),
                .read_addr1(Rs),
                .read_addr2(Rt),
                .read_data1(reg_data1[t]),
                .read_data2(reg_data2[t]),
                .write_addr(write_addr),
                .write_data(write_data[t]),
                .write_enable(write_enable[t]),
                .block_id(block_id),
                .thread_id(t[7:0]),
                .threads_per_block(THREADS_PER_BLOCK[7:0])
            );

            simple_alu alu_inst (
                .A(reg_data1[t]),
                .B(reg_data2[t]),
                .operation(opcode),
                .result(alu_result[t]),
                .NZP(NZP[t])
            );

            load_store_unit #(.DATA_MEM_ADDR_BITS(DATA_MEM_ADDR_BITS), .DATA_MEM_DATA_BITS(DATA_MEM_DATA_BITS)) lsu_inst (
                .clk(clk),
                .reset(reset),
                .load_enable(is_ldr && active_threads[t]),
                .store_enable(is_str && active_threads[t]),
                .address(reg_data1[t]),
                .store_data(reg_data2[t]),
                .load_data(lsu_load_data[t]),
                .data_mem_read_valid(data_mem_read_valid[t]),
                .data_mem_read_address(data_mem_read_address[t]),
                .data_mem_read_ready(data_mem_read_ready[t]),
                .data_mem_read_data(data_mem_read_data[t]),
                .data_mem_write_valid(data_mem_write_valid[t]),
                .data_mem_write_address(data_mem_write_address[t]),
                .data_mem_write_data(data_mem_write_data[t]),
                .data_mem_write_ready(data_mem_write_ready[t]),
                .lsu_done(lsu_done[t])
            );
        end
    endgenerate

    // Writeback control logic (sequential)
    always_ff @(posedge clk or negedge reset) begin
        if (~reset) begin
            write_addr <= 4'b0;
            for (int t = 0; t < THREADS_PER_BLOCK; t++) begin
                write_enable[t] <= 1'b0;
                write_data[t] <= 8'b0;
            end
        end else begin
            write_addr <= Rd;
            for (int t = 0; t < THREADS_PER_BLOCK; t++) begin
                write_enable[t] <= 1'b0;
                write_data[t] <= 8'b0;  // Default
                if (active_threads[t] && (core_state == WRITEBACK)) begin
                    if (is_add || is_sub || is_mul || is_div) begin
                        write_enable[t] <= 1'b1;
                        write_data[t] <= alu_result[t];
                    end else if (is_const) begin
                        write_enable[t] <= 1'b1;
                        write_data[t] <= IMM8;
                    end else if (is_ldr) begin
                        write_enable[t] <= 1'b1;
                        write_data[t] <= lsu_load_data[t];  // Mux LSU output here
                    end
                end
            end
        end
    end

endmodule
