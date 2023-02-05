## zsc

zig-sequence-compression (zsc) - simple library for compression of integer/float sequences

Currently there are two algorithms implemented:
1. gorilla - efficient algorithm for sequence compression presented at the [work from Facebook](https://www.vldb.org/pvldb/vol8/p1816-teller.pdf)
2. entropy - ad-hoc algorithm which compress batches of numbers bit by bit separately

You can experiment with the tool via CLI interface. Just grab a binary file and try to compress it:
```bash
$> make build-release
$> ./zig-out/bin/zsc load -i examples/f64-128.txt -t float -w 64 | ./zig-out/bin/zsc compress -a entropy -w 64 > /dev/null
# outputs:
# load: stdin => stdout : 40.63% (2520 => 1024 bytes)
# compress: stdin => stdout : 69.63% (1024 => 713 bytes)
```
