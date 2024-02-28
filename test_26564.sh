test_dir="$HOME/dev/test_data"
bitcoin_dir="$HOME/dev/bitcoin"

for file in "$bitcoin_dir"/src/test/*_tests.cpp; do
    test_name=$(basename $file | sed 's/\.[^.]*$//')

    $bitcoin_dir/src/test/test_bitcoin -t $test_name -- -testdatadir="$test_dir"

    if [ $? -ne 0 ]; then
        echo $test_name failed!
        exit 1
    fi
done
