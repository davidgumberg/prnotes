bitcoin_dir="$HOME/dev/bitcoin"

test_absolute_dir="$HOME/dev/test_data"
test_relative_dir="test_data"

for file in "$bitcoin_dir"/src/test/*_tests.cpp; do
    test_name=$(basename $file | sed 's/\.[^.]*$//')

    $bitcoin_dir/src/test/test_bitcoin -t $test_name -- -testdatadir="$test_absolute_dir"
    if [ $? -ne 0 ]; then
        echo $test_name failed with absolute dir $test_absolute_dir!
        exit 1
    fi

    $bitcoin_dir/src/test/test_bitcoin -t $test_name -- -testdatadir="$test_relative_dir"
    if [ $? -ne 0 ]; then
        echo $test_name failed with relative dir $test_relative_dir!
        exit 1
    fi

done
