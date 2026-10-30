extension Array {
    /// The index of the last element whose key is at most `value`, in an array sorted by that key;
    /// nil when every key is greater. O(log n).
    public func lastIndex<Key: Comparable>(atOrBefore value: Key, by key: (Element) -> Key) -> Int? {
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            if key(self[middle]) <= value { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? nil : low - 1
    }
}
