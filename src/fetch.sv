`timescale 1ns/1ns

// Fetch module: Retrieves instructions from program memory using a valid/ready handshake
module fetch #(
    parameter PROGRAM_MEM_ADDR_BITS = 8,
    parameter PROGRAM_MEM_DATA_BITS = 16
) (
    input clk,
    input reset,
    input logic enable, // Signal to start fetching
    input logic [PROGRAM_MEM_ADDR_BITS-1:0] PC, // Program counter
    output logic program_mem_read_valid, // Request to read from program memory
    output logic [PROGRAM_MEM_ADDR_BITS-1:0] program_mem_read_address, // Memory address
    input logic program_mem_read_ready, // Memory ready signal
    input logic [PROGRAM_MEM_DATA_BITS-1:0] program_mem_read_data, // Fetched instruction
    output logic [PROGRAM_MEM_DATA_BITS-1:0] instruction, // Output instruction
    output logic fetch_done // Indicates fetch completion
);

    fetch_state_t state;

    // State machine to manage fetch process
    always_ff @(posedge clk or negedge reset) begin
        if (~reset) begin
            state <= FETCH_IDLE;
            program_mem_read_valid <= 0;
            program_mem_read_address <= 0;
            instruction <= 0;
            fetch_done <= 0;
        end else begin
            case (state)
                FETCH_IDLE: begin
                    if (enable) begin
                        state <= FETCH_REQUEST;
                        program_mem_read_valid <= 1;
                        program_mem_read_address <= PC;
                        fetch_done <= 0;
                    end
                end
                FETCH_REQUEST: begin
                    if (program_mem_read_ready) begin
                        instruction <= program_mem_read_data;
                        state <= FETCH_WAIT_READY;
                    end
                end
                FETCH_WAIT_READY: begin
                    program_mem_read_valid <= 0;
                    fetch_done <= 1;
                    state <= FETCH_IDLE;
                end
                default: state <= FETCH_IDLE;
            endcase
        end
    end
endmodule
