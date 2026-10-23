#!/bin/sh
stty size > '/Users/prince/Desktop/terminal_project/bench/results/libertty.size'
'/Users/prince/Desktop/terminal_project/bench/vtebench/target/release/vtebench' --silent -b '/Users/prince/Desktop/terminal_project/bench/vtebench/benchmarks' --min-bytes 8388608 --dat '/Users/prince/Desktop/terminal_project/bench/results/libertty.dat' --max-secs 8 2> '/Users/prince/Desktop/terminal_project/bench/results/libertty.log'
touch '/Users/prince/Desktop/terminal_project/bench/results/libertty.done'
