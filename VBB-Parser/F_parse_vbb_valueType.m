function vbbValueType = F_parse_vbb_valueType(vbbValue)
    % This function holds definitions for the type of value stored in a VBB
    % file.
    %
    % Before a value is stored in a VBB there is a single byte identifying
    % the type of value that comes after. They are as follows:
    %    
    %  **ValueType (Number stored)**
    %    None (0)
    %    Byte (1)
    %    UInt16 (2)
    %    Int16 (3)
    %    UInt32 (4)
    %    Int32 (5)
    %    UInt64 (6)
    %    Int64 (7)
    %    Single (8)
    %    Double (9)
    %    Time (10)
    %    DateTime (11)
    %    String (12)
    %    ByteArray (13) - not present in the documentation might need this later though

    switch (vbbValue)
        case 0
            vbbValueType = 'None';
        case 1
            vbbValueType = 'uint8';
        case 2
            vbbValueType = 'uint16';
        case 3
            vbbValueType = 'int16';
        case 4
            vbbValueType = 'uint32';
        case 5
            vbbValueType = 'int32';
        case 6
            vbbValueType = 'uint64';
        case 7
            vbbValueType = 'int64';
        case 8
            vbbValueType = 'single';
        case 9
            vbbValueType = 'double';
        case 10
            vbbValueType = 'time';
        case 11
            vbbValueType = 'datetime';
        case 12
            vbbValueType = 'string';
        case 13
            vbbValueType = 'byteArray';
        otherwise
            error('Unknown VBBValueType - %d', vbbValue);
    end
end