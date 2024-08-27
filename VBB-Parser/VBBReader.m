classdef VBBReader < handle
    % This class is responsible for parsing the data out of a VBB file. It
    % uses our custom FileReader class to access the data in a file.

    properties

        % This is the endianness of the VBB file
        fileEndianness;

        % Flag indicating if the file endianness matches computer endianness. 0 = false, 1 = true
        endiannessMatch;

        % The format version for this VBB file - changes how some of the values are stored
        formatVersion;

        % Denotes if the sample timestamps in the file are in UTC time
        UTC;

        % This is an instance of the custom FileReader class
        fileReader;

        % This is where the data is stored once read from the file
        vbbFile;

        % A boolean telling the file reader if we've gotten to the part of the file with samples or not
        samplesReached;


        % This is used to more efficiently extract data from the VBB file.
        % We direct address this so the channel group in position 61 is the group with ID 61. 
        channelGroupData = struct('channelLocations', {}, 'channelStartIndex', {}, 'channelEndIndex', {}, 'groupLength', {}, 'instanceLocations', {}, 'instanceData', {});

    end


    methods
    
        function parsedVBBFile = ReadVBBFile(obj, filePath)
            % The constructor for this class. Provide a VBB file path and
            % it will read the file in and validate the headers to ensure
            % the file is in the correct format.

            % We default to big endianness as the header bytes are stored in big endian format.
            % This needs to be set here, the other properties can be read from the header bytes.
            obj.fileEndianness = 'B';
            obj.SetEndiannessFlag();
            obj.samplesReached = false;
            
            fprintf('Loading VBB file...\n');

            % Initialise the file reader and VBBFile objects
            obj.fileReader = FileReader(filePath);
            obj.vbbFile = VBBFile;

            fprintf('VBB loaded into memory\n');

            % Read through the header bytes of the file. This includes
            % channel and group definitions. It will continue to read until
            % we reach a sample group
            obj.ReadVBBHeaders();
            
            fprintf('Headers read\n');

            % Once the headers have been read we can set up for reading the
            % data samples from the file
            obj.SetUpForSampleReading();

            fprintf('Reading sample group positions...\n');

            % Now we can skip through the file, recording the positions of
            % each instance of a sample group
            obj.ReadSampleGroupLocations(); 
            
            fprintf('Samples extracted\n');
            % With all the samples extracted we now need to correct any
            % timestamp jumps caused by a recording over midnight UTC
            obj.CorrectUTCMidnightRollovers();


            parsedVBBFile = obj.vbbFile;

            obj.fileReader.CloseFile();
        end


        function ReadVBBHeaders(obj)
            % This function takes a VBB byte array and checks the header
            % bytes to get the format, endianness and timestamps for when
            % the file was created and last modified.
            %
            % The outputs are DateTime objects

            %---------------------------------------------%

            % Read the first 3 bytes in the file. These are headers that indicate
            % if the file is in VBB format - "V", "B", "B"
            vbbFileHeaders = obj.fileReader.ReadBytes(3);
            expectedHeaders = uint8([0x56; 0x42; 0x42]);

            if ~isequal(vbbFileHeaders, expectedHeaders)
                error('Invalid file format.');
            end


             % The next byte contains the format of the VBB file being dealt with
            obj.formatVersion = obj.ReadPrimitive('uint8', 1);

            % The next 4 bytes contain the flags used to notify how the file is set up.
            flags = obj.ReadPrimitive('uint32', 4);

            % The first bit denotes the endianness of the file - 0 = little, 1 = big
            if bitand(flags, uint32(0x0001)) == 0x0001
                obj.fileEndianness = 'B';
            else
                obj.fileEndianness = 'L';
            end
            obj.SetEndiannessFlag();

            % The second bit denotes the sample time - 0 = local time, 1 = UTC
            if bitand(flags, uint32(0x0002)) == 0x0002
                obj.UTC = true;
            else
                obj.UTC = false;
            end

            % The next 8 bytes contain the datetime information for when the file was
            % created
            obj.vbbFile.fileCreated = obj.ParseVBBValue('datetime');
            % The next 8 bytes contain the datetime information for when the file was
            % last modified
            obj.vbbFile.fileLastModified = obj.ParseVBBValue('datetime');
          

            % Read through the file until we reach data samples - this will
            % read in all of the channel/group/dictionary/EEPROM
            % information
            while ~obj.samplesReached
                % Read out the next byte - this is the next section's record identifier
                sectionRecordID = obj.ReadPrimitive('uint8', 1);

                % Parse the data from the record
                obj.ParseVBBRecord(sectionRecordID);
            end
        end

        
        function SetEndiannessFlag(obj)
            % Get the endianness of the computer that this code is being ran on if
            % not already obtained.
            % Returns 'B' or 'L'
            [~,~, computer_endianness] = computer;

            % Set the flag to tell the VBBFileReader if the endianness of
            % the file and the computer match
            obj.endiannessMatch = 1;
            if ~strcmp(obj.fileEndianness, computer_endianness)
                obj.endiannessMatch = 0;
            end
        end


        function sizeBytes = GetVBBTypeSize(~, valueType)
            % This takes an input string representing a value type, and returns the
            % number of bytes that said type comprises

            switch valueType
                case {'uint8', 'int8'}
                    sizeBytes = 1;
                case {'uint16', 'int16'}
                    sizeBytes = 2;
                case {'uint32', 'int32', 'single'}
                    sizeBytes = 4;
                case {'uint64', 'int64', 'double'}
                    sizeBytes = 8;
                otherwise
                    error('Unknown ValueType %s', valueType);
            end
        end


        %% Efficient sample reading functions

        function SetUpForSampleReading(obj)
            % Sample reading works as follows: 
            % - logic/process of each step
            % ~ the resulting data structure
            %
            %   - jump from one sample group ID to the next, noting where
            %     each instance of a sample group appears in the file.
            %   ~ a row vector of integers
            %
            %   - using the locations of each instance for each sample
            %     group, slice the byte array to extract every instance of
            %     each sample group
            %   ~ a 2D array, where each column is the raw bytes representing 
            %     each instance of a sample group in the file
            %
            %   - using the locations of each channel in a sample group,
            %     slice each sample group array to get a list of all the
            %     bytes making up each instance of a channel
            %   ~ a 2D array where each column is the raw bytes
            %     representing each instance of a channel in the file
            %
            %   - transpose then typecast these arrays into the data type 
            %     of the channel to get out the stored data for each 
            %     channel in the file
            %   ~ a column vector of values representing the stored channel
            %     in the VBB file
            %
            % In order to achieve this we need to know the length of each
            % sample group. We calculate this using the data types of each
            % channel given in the ChannelDefinitions struct. We also need
            % to know the locations of each channel within a sample group.
            % We calculate while calculating the length of a sample group.
            %
            % To speed things up, we use direct addressing for the sample 
            % group definitions (we put sample group ID 14 at position 14
            % in the GroupDefinitions array). We also use direct addressing
            % for the channels given in each GroupDefinitions entry
            % (instead of Channel ID we provide the index of that channel
            % in the ChannelDefinitions struct).
            
            longestChannelGroup = 0;

            % Go though the list of channel group definitions in the VBB
            for i = 1:length(obj.vbbFile.channelGroupDefinitions)
                
                groupID = obj.vbbFile.channelGroupDefinitions(i).groupID;
                channelIDs = obj.vbbFile.channelGroupDefinitions(i).channelIDs;
                numChannels = obj.vbbFile.channelGroupDefinitions(i).numChannels;

                % Channel locations within the ChannelDefinitions struct
                channelLocations = zeros(numChannels, 1);

                % Length of the channel group. The 6 bytes at the start are the sample group record byte, 
                % the 4 timestamp bytes and then the sample group ID byte
                groupLength = 1 + 4 + 1;
                % Locations of each channel start and end within a channel group
                channelStartIndices = zeros(numChannels, 1);
                channelEndIndices = zeros(numChannels, 1);

                % For each of the channel IDs in the group definition, find
                % their location in the channelDefinitions struct
                %
                % While looping through each channel, we take the size of
                % each channel data type and add it to the length of the
                % current channel group. We also note where this channel
                % starts and ends within the channel group
                for j = 1:numChannels
                    channelIndex = find([obj.vbbFile.channelDefinitions.channelID] == channelIDs(j));

                    if isempty(channelIndex)
                        error('ChannelID not found in channel definitions struct %d', channelIDs(j));
                    end
                    
                    % Note the location of the channel in the channel definitions struct
                    channelLocations(j) = channelIndex;

                    % Note the start index of this channel in the channel group
                    channelStartIndices(j) = groupLength + 1;
                    
                    % Get the channel type from the channel definitions struct
                    channelType = obj.vbbFile.channelDefinitions(channelIndex).valueType;
                    % Add the size of this channel to the group length
                    groupLength = groupLength + obj.GetVBBTypeSize(channelType);

                    % Note the end index of this channel in the channel group
                    channelEndIndices(j) = groupLength;
                end
                

                channelGroupData_NewStruct = struct('channelLocations', channelLocations, ...
                                                    'channelStartIndex', channelStartIndices, ...
                                                    'channelEndIndex', channelEndIndices, ...
                                                    'groupLength', groupLength, ...
                                                    'instanceLocations', [], ...
                                                    'instanceData', []);

                % Add these calculated channel variables to the channelGroupData struct
                obj.channelGroupData(groupID) = channelGroupData_NewStruct;

                % If this is the longest channel group, then update the
                % value
                if longestChannelGroup < groupLength
                    longestChannelGroup = groupLength;
                end
            end
            
            % Update the length of the buffer in the FileReader. It needs
            % to be the length of the longest channel group, plus an extra
            % 2 bytes to be sure
            obj.fileReader.sectionBufferLength = longestChannelGroup + 2;

        end


        function ReadSampleGroupLocations(obj)
            % This function reads through the file, jumping from each
            % sample group record ID byte to the next, making a note of the
            % group ID for each sample and where it is.        
            isEoF = false;
            
            % While we're not at both the end of the file and the end of
            % the current data section, keep looping
            while ~isEoF

                % Every time we get to the end of a section of data we need
                % to extract the data. Then read the next section from the
                % file

                [recordID, isEoS] = obj.ReadPrimitive('uint8', 1);

                % If we're at the end of a section, go back one byte (so
                % we can read the record identifier again) parse out the
                % current section of data, then move on to the next section
                if isEoS
                    
                    obj.fileReader.AdvanceThroughFile(-1);
                   
                    % Extract the sample group bytes using their locations
                    % in the current data section. Then extract the
                    % channels from each sample group
                    obj.ExtractSampleGroupData();
                    obj.ExtractChannelData();
                    
                    isEoF = obj.fileReader.ReadNextSection();

                    % Make sure to reset the instance locations for the
                    % sample groups. We don't want the old locations for
                    % sample groups as they refer to data that is now out
                    % of memory
                    obj.ResetSampleGroupInstanceLocations();

                    % Output a progress update for the user based on where
                    % we are in the file
                    percentageThroughFile = (double(obj.fileReader.overallIndex)/obj.fileReader.overallLength)*100;
                    fprintf('%.0f%%\n', percentageThroughFile);

                    continue;
                end

                % Verify that this record is a sample group. If not, we
                % need to parse the record elsewhere.
                if recordID ~= 9
                    % If this record isn't a sample group then we need to parse it
                    obj.ParseVBBRecord(recordID);
                    continue;
                end

                % Now read the ID of the sample group. Skip forward past
                % the 4 timestamp bytes to read this
                obj.fileReader.AdvanceThroughFile(4);
                [groupID, ~] = obj.ReadPrimitive('uint8', 1);

                % Get the struct for the group ID
                groupLength = obj.channelGroupData(groupID).groupLength;
                
                % Note where this sample group appears in the file. We want the location of the record ID, 
                % so go back enough bytes to cover the read group ID, 4 timestamp bytes and the record ID byte
                obj.channelGroupData(groupID).instanceLocations(end + 1) = obj.fileReader.sectionIndex - 6;

                % Advance through the file to the next sample group location - use the length of this sample group to do so
                % but subtract 6 as the group length includes the group ID byte we've just read, the 4 timestamp bytes and 
                % the record ID byte
                obj.fileReader.AdvanceThroughFile(groupLength - 6);
            end
        end


        function ResetSampleGroupInstanceLocations(obj)
            % This resets the indices of each sample group location in the VBB file. This is used whenever we move into a new
            % data section

            for i = 1:length(obj.channelGroupData)
                if ~isempty(obj.channelGroupData(i).channelLocations)
                    obj.channelGroupData(i).instanceLocations = [];
                end
            end
        end


        function ExtractSampleGroupData(obj)
            % This function can only run once the positions of each sample
            % group have been found in the byte array. We take the indices
            % of each sample group
            
            % Let's manipulate the VBB byte array into sample group sections
            for i = 1:length(obj.channelGroupData)

                % Make sure there's a channel group at this position in the struct (this accounts for our direct 
                % addressing of sample groups). It also solves issues if we have a channel group defined and no 
                % samples were written to the VBB file.
                if isempty(obj.channelGroupData(i).instanceLocations)
                    continue;
                end

                % The group length plus the timestamp at the start
                sectionLength = obj.channelGroupData(i).groupLength;

                % Get the row vector for the start index of each instance
                % of this sample group in the byte array
                startLocations = obj.channelGroupData(i).instanceLocations;

                % Create a column vector representing the position of each
                % byte in the sample group
                offsets = (0:(sectionLength-1))';

                % Generate the index matrix using implicit expansion. This creates a matrix where every column represents an
                % instance of a sample group appearing in the byte array. Each row represents the index of each byte that appears
                % in the sample group.
                indices = startLocations + offsets;

                % Index into the VBB byte array using the indices matrix. This effectively takes each element in the indices 
                % matrix and replaces its value with the corresponding value at that index in the byte array.
                dataMatrix = obj.fileReader.sectionArray(indices);

                % Add each set of data to a struct
                obj.channelGroupData(i).instanceData = dataMatrix;
            end
        end


        function ExtractChannelData(obj)
            % This function must run after ExtractSampleGroupData. It takes
            % the sample group byte arrays as indexed from the byte array,
            % slices out each channel, then parses the data. We then put
            % each channel's data along with the corresponding timestamps
            % into the ChannelDefinitions struct in a VBBFile object.

            % Loop through each Sample Group definition
            for i = 1:length(obj.channelGroupData)
                
                groupData = obj.channelGroupData(i);

                % Make sure there's data in here
                if isempty(groupData.instanceData)
                    continue;
                end

                % Extract the timestamp data first. It runs from bytes 2-5
                timestampDataBytes = groupData.instanceData(2:5, :);
                % Reshape into a single column vector
                timestampDataBytes = reshape(timestampDataBytes, [], 1);
                % Cast it into the correct data type
                timestampData = typecast(timestampDataBytes, 'uint32');
                % Swap the byte order if the file and computer endianness don't match
                if obj.endiannessMatch == 0
                    timestampData = swapbytes(timestampData);
                end

                % Convert these timestamps to seconds (cast to a double array first to avoid truncation)
                % They are stored in 100us steps so we divide by 10,000 (or multiply by 1e-4) to get
                % seconds
                timestampData = double(timestampData) * 1e-4;

                % For each channel in this sample group extract the data, typecast it, then add it to that ChannelDefinition's data array
                for j = 1:length(groupData.channelLocations)

                    % Extract information about this channel from the structs. We need the channel data type and the start
                    % and end indices of the channel in the sample group byte array
                    channelDefIndex = groupData.channelLocations(j);
                    channelDataType = obj.vbbFile.channelDefinitions(channelDefIndex).valueType;

                    channelScale = obj.vbbFile.channelDefinitions(channelDefIndex).scale;
                    channelOffset = obj.vbbFile.channelDefinitions(channelDefIndex).offset;

                    startIndex = groupData.channelStartIndex(j);
                    endIndex = groupData.channelEndIndex(j);

                    % Extract the channel bytes from the sample group instances 
                    channelDataBytes = groupData.instanceData(startIndex:endIndex, :);
                    % Reshape into a single column vector
                    channelDataBytes = reshape(channelDataBytes, [], 1);

                    % Cast it into the correct data type
                    channelData = typecast(channelDataBytes, channelDataType);

                    % Swap the byte order if the file and computer endianness don't match
                    if obj.endiannessMatch == 0
                        channelData = swapbytes(channelData);
                    end

                    
                    % Convert the channel into a double array to prevent any rounding error issues 
                    % when applying the scale and offset
                    channelData = double(channelData);
                                        
                    % Apply the channel scale and offset to each entry
                    channelData = (channelData * channelScale) + channelOffset;
                    

                    % Put the extracted data into the end of the channel definition array 
                    obj.vbbFile.channelDefinitions(channelDefIndex).timestamps = [obj.vbbFile.channelDefinitions(channelDefIndex).timestamps; timestampData];
                    obj.vbbFile.channelDefinitions(channelDefIndex).data = [obj.vbbFile.channelDefinitions(channelDefIndex).data; channelData];
                end

            end
        end


        function CorrectUTCMidnightRollovers(obj)
           
            for i = 1:length(obj.vbbFile.channelDefinitions)
                % Get the timestamps out for the channel
                timestampData = obj.vbbFile.channelDefinitions(i).timestamps;
                % Apply the UTC rollover correction
                correctedTimestampData = CorrectUTCMidnightRolloverForChannel(obj, timestampData);
                % Put the data back into the channel
                obj.vbbFile.channelDefinitions(i).timestamps = correctedTimestampData;


                % If we're dealing with the 'time' channel then we also need to correct the data inside the channel
                channelShortName = obj.vbbFile.channelDefinitions(i).shortName;
                channelShortName = reshape(channelShortName, 1, []);
                % Check to see if this channel is the 'time' channel
                if (strcmp(channelShortName, "time"))
                    timeChannel = obj.vbbFile.channelDefinitions(i).data;
                    correctedTimeChannel = CorrectUTCMidnightRolloverForChannel(obj, timeChannel);
                    obj.vbbFile.channelDefinitions(i).data = correctedTimeChannel;
                end
            end
        end
        

        function CorrectedTimestamps = CorrectUTCMidnightRolloverForChannel(obj, timestampData)
            
            % For files that go over midnight UTC, the timestamp value
            % will reset to zero. Thus, we need to find where this jump
            % happens and add a day's worth of seconds to each
            % subsequent timestamp
            timeDiffs = diff(timestampData);
            
            % The rollover point will be 0 - 86,400 (there are 86,400
            % seconds in a day)
            timeJumps = find(timeDiffs <= 0);

            % For each time jump, add 86,400 to the remaining timestamps
            for j = 1:length(timeJumps)
                timestampData(timeJumps(j)+1:end) = timestampData(timeJumps(j)+1:end) + 86400;
            end

            CorrectedTimestamps = timestampData;
            return;
        end


        %% Simple VBB creation function

        function simpleVBB = CreateSimpleVBB(obj)
            % This takes the VBBFile object as extracted from a VBB file
            % and simplifies it to match the output of F_vboload in
            % Racelogic's VBO-MATLAB v1.5 converter MATLAB script
            % 
            % However, VBB files can contain channels logged at
            % different frequencies. So, we output a struct that matches
            % the format of the VBO converter with each set of channels
            % recorded at the same frequency grouped together.

            recordedFrequencies = [];
            sameFrequencyChannels = struct('frequency', {}, 'channelDefinitions', {});

            % We need to group channels that were recorded at the same
            % frequency. Otherwise we'll get arrays filled with NaN values
            % for the lower frequency channels
            for i = 1:length(obj.vbbFile.channelDefinitions)
                
                % If the channel has no samples then skip it
                if isempty(obj.vbbFile.channelDefinitions(i).timestamps)
                    continue;
                % See if the timestamps array has 1 element (ie it is scalar)
                elseif isscalar(obj.vbbFile.channelDefinitions(i).timestamps)
                    % If there is only 1 entry in this timestamp array then
                    % set the frequency to 0
                    tempFrequency = 0;
                else
                    % Estimate the frequency of this channel
                    tempFrequency = (obj.vbbFile.channelDefinitions(i).timestamps(end) - obj.vbbFile.channelDefinitions(i).timestamps(1))/length(obj.vbbFile.channelDefinitions(i).timestamps);
                    % The above calculates the average time between samples in
                    % seconds. Turn this into Hz (1/s)
                    %
                    tempFrequency = round(1/tempFrequency);
                end

                frequencyIndex = find(recordedFrequencies == tempFrequency);

                % If we haven't noted this frequency yet then add it to the list
                if isempty(frequencyIndex)
                    recordedFrequencies(end + 1) = tempFrequency;
                    sameFrequencyChannels(end + 1) = struct('frequency', tempFrequency, 'channelDefinitions', obj.vbbFile.channelDefinitions(i));
                else
                    % If we've already recorded channels at this frequency then add this channel
                    sameFrequencyChannels(frequencyIndex).channelDefinitions(end + 1) = obj.vbbFile.channelDefinitions(i);
                end
            end

            simpleVBB = struct(); % 'frequency', {}, 'timestamps', {}, 'channelGroup', {});

            % Now go through each group of same-frequency channels in turn and align their samples
            for i = 1:length(recordedFrequencies)
                [alignedChannels, alignedTimestamps] = obj.AlignChannelSamples(sameFrequencyChannels(i));
                
                % Add the GNSS timestamps as a separate array to the
                % simpleVBBFile
                gnssTimeName = reshape(char('time (GNSS)'), [], 1);
                timeChannelStruct = struct('name', gnssTimeName, ...
                    'units', 's', ...
                    'data', alignedTimestamps);

                alignedChannels(end+1) = timeChannelStruct;


                % Create the field name dynamically using the frequency of
                % the channel group
                fieldName = sprintf('channels_%dHz', recordedFrequencies(i));

                simpleVBB.(fieldName) = alignedChannels;
            end

            return;
        end


        function [alignedChannels, allTimestamps] = AlignChannelSamples(~, sameFrequencyChannels)
            % We take each channel's timestamp array and combine them into a
            % single unique array. We then match up each channel's
            % timestamp to the unique timestamp array, inserting NaN for
            % any channels that didn't record values at a timestamp
            %
            % sameFrequencyChannels is a struct with the same layout as the
            % channelDefinitions struct in a VBBFile class object

            numChannels = length(sameFrequencyChannels.channelDefinitions);

            if numChannels == 0
                fprintf('Error: unable to create simple VBB file, no channels loaded');
                return;
            end

            alignedChannels(numChannels) = struct('name', [], 'units', [], 'data', []);

            % Go through every channel and combine the timestamp arrays
            % into a single unique array.
            allTimestamps = [];

            for i = 1:numChannels
                allTimestamps = unique([allTimestamps; sameFrequencyChannels.channelDefinitions(i).timestamps]);
            end

            numTimestamps = length(allTimestamps);

            % Go though each channel, match the timestamps to the unique
            % timestamp array, initialise an array of NaN, the put each
            % channel value with matching timestamps into the correct
            % position in the array
            for i = 1:numChannels

                channelName = sameFrequencyChannels.channelDefinitions(i).shortName;
                channelUnits = sameFrequencyChannels.channelDefinitions(i).units;

                % See which indicies in the channel have matching
                % timestamps to the unique timestamp array
                [~, indices] = ismember(sameFrequencyChannels.channelDefinitions(i).timestamps, allTimestamps);

                % Populate the aligned channel with NaN values as default.
                alignedChannel = NaN(numTimestamps, 1);
                % Insert the channel into the correct position in the aligned channel array
                alignedChannel(indices) = sameFrequencyChannels.channelDefinitions(i).data;


                % Add the data to the simpleVBB struct
                alignedChannelStruct = struct('name', channelName, ...
                                              'units', channelUnits, ...
                                              'data', alignedChannel);

                alignedChannels(i) = alignedChannelStruct;
            end


        end


        %% VBB record type parsing function

        function ParseVBBRecord(obj, vbbRecordID)
            % Before a record is stored in a VBB there is a single byte identifying
            % the type of record that comes after. They are as follows:
            %
            %  **RecordType (Number stored)**
            %    GroupDefinition (5)
            %    DictionaryItem (6)
            %    ChannelDefinition (7)
            %    ChannelGroupDefiniton (8)
            %    SampleGroup (9)
            %    BinaryDump (13)
            %
            % Inputs:
            % vbbRecordID - integer

            %---------------------------------------------%

            % Figure out what parsing needs to be done based on the record type
            % that's been read
            switch vbbRecordID
                case 5
                    % A group definition record is written as follows:
                    % byte 1 - 05 (channel group definition identifier)
                    % byte 2 - the group ID
                    % n bytes - group name string (7 bit encoded length at start)

                    %---------------------------------------------%

                    % We've already read the first byte in order to have gotten to this
                    % point, so the next entry is the group ID
                    groupDef_GroupID = obj.ReadPrimitive('uint8', 1);
                    groupDef_Name = obj.ParseVBBValue('string');


                    % Add this new entry to the file's group definitions
                    groupDef_NewStruct = struct('groupID', groupDef_GroupID, ...
                                                'groupName', groupDef_Name);
                    obj.vbbFile.groupDefinitions(end + 1) = groupDef_NewStruct;

                case 6
                    % A dictionary record is written as follows:
                    % byte 1 - 06 (Dictionary item identifier)
                    % byte 2 - group ID
                    % n bytes - dictionary item name string (7 bit encoded length at start)
                    % n + 1 byte - value type identifier
                    % m bytes - the value of the dictionary item

                    %---------------------------------------------%

                    % We've already read the first byte in order to have gotten to this
                    % point, so the next entry is the group ID
                    dictItem_GroupID = obj.ReadPrimitive('uint8', 1);

                    % When parsing VBB strings, the parser function looks for the
                    % bytes that represent the length of that string. So we don't
                    % need to manually look for the string length
                    dictItem_Name = obj.ParseVBBValue('string');

                    % Parse the next byte to find out what type of object this
                    % dictionary item is (int, single etc)
                    dictItem_ValueTypeByte = obj.ReadPrimitive('uint8', 1);
                    dictItem_ValueType = F_parse_vbb_valueType(dictItem_ValueTypeByte);

                    % Read the dictionary item itself
                    dictItem_Value = obj.ParseVBBValue(dictItem_ValueType);


                    % Add this new entry to the file's dictionary
                    dictItem_NewStruct = struct('name', dictItem_Name, ...
                                                'value', dictItem_Value, ...
                                                'valueType', dictItem_ValueType, ...
                                                'groupID', dictItem_GroupID);
                    obj.vbbFile.dictionary(end + 1) = dictItem_NewStruct;

                case 7
                    % A channel definition record is written as follows:
                    % byte 1 - 07 (channel definition item identifier)
                    % bytes 2 and 3 - the channel ID
                    % byte 4 - group to which the channel is assigned
                    % n bytes - channel short name string (7 bit encoded length at start)
                    % m bytes - channel long name string (7 bit encoded length at start)
                    % p bytes - channel units string (7 bit encoded length at start)
                    % p + 1 - channel data type
                    % p + 2 - channel scale (as double)
                    % p + 10 - channel offset (as double)
                    % p + 11 - channel meta data string (7 bit encoded length at start)

                    %---------------------------------------------%

                    % We've already read the first byte in order to have gotten to this point
                    % so we're reading the channel ID
                    channelDef_ID = obj.ReadPrimitive('uint16', 2);
                    channelDef_GroupID = obj.ReadPrimitive('uint8', 1);
                    channelDef_ShortName = obj.ParseVBBValue('string');
                    channelDef_LongName = obj.ParseVBBValue('string');
                    channelDef_Units = obj.ParseVBBValue('string');

                    channelDef_ValueTypeByte = obj.ReadPrimitive('uint8', 1);
                    channelDef_ValueType = F_parse_vbb_valueType(channelDef_ValueTypeByte);

                    channelDef_Scale = obj.ReadPrimitive('double', 8);
                    channelDef_Offset = obj.ReadPrimitive('double', 8);
                    channelDef_Metadata = obj.ParseVBBValue('string');


                    % For some of the channel scales, we use decimal values which cannot be accurately 
                    % represented in binary format. For these we will manually change the values to be
                    % 'correct'.
                    if (round(channelDef_Scale,3) == 0.001)
                        channelDef_Scale = 0.001;
                    elseif (round(channelDef_Scale,1) == 3.6)
                        channelDef_Scale = 3.6;
                    end


                    % Add this new entry to the file's Channel definitions map
                    channelDef_NewStruct = struct('channelID', channelDef_ID, ...
                                                  'groupID', channelDef_GroupID, ...
                                                  'shortName', channelDef_ShortName, ...
                                                  'longName', channelDef_LongName, ...
                                                  'units', channelDef_Units, ...
                                                  'valueType', channelDef_ValueType, ...
                                                  'scale', channelDef_Scale, ...
                                                  'offset', channelDef_Offset, ...
                                                  'metaData', channelDef_Metadata, ...
                                                  'timestamps', [], ...
                                                  'data', []);
                    obj.vbbFile.channelDefinitions(end + 1) = channelDef_NewStruct;

                case 8
                    % A channel group definition record is written as follows:
                    % byte 1 - 08 (channel group definition identifier)
                    % byte 2 - channel group ID
                    % bytes 2 and 3 - number of channels in the group
                    % each subsequent pair of bytes is a channel until we've read as many channels as defined in bytes 2 and 3

                    %---------------------------------------------%

                    % We've already read the first byte in order to have gotten to this point
                    % so we're reading the group ID
                    channelGroup_ID = obj.ReadPrimitive('uint8', 1);
                    channelGroup_NumChannels = obj.ReadPrimitive('uint16', 2);

                    % Create the channel array that we will fill with channel IDs
                    channelGroup_ChannelIDArray =  zeros(channelGroup_NumChannels, 1, 'uint16');

                    % Now read out the list of channel IDs that are in this
                    % group. Their order in this list is the order samples
                    % will appear later on in the file
                    for i = 1:channelGroup_NumChannels
                        channelGroup_ChannelIDArray(i, 1) = obj.ReadPrimitive('uint16', 2);
                    end

                    % Add this new entry to the channel group definitions
                    channelGroup_NewStruct = struct('groupID', channelGroup_ID, ...
                                                    'numChannels', channelGroup_NumChannels, ...
                                                    'channelIDs', channelGroup_ChannelIDArray);
                    obj.vbbFile.channelGroupDefinitions(end + 1) = channelGroup_NewStruct;

                case 9
                    % A sample group record is written as follows:
                    % byte 1 - 09 (sample group definition identifier)
                    % bytes 2,3,4 and 5 - the timestamp for this group (uint32)
                    % byte 6 - the group ID for this sample group
                    % The rest of the bytes are each of the channels as defined in the
                    % group definition

                    %---------------------------------------------%

                    % Reading each sample group out byte by byte is far too
                    % slow. So, we don't read individual records in with
                    % this function.
                    obj.samplesReached = true;
                    % Go back one sample in the file array to the start of
                    % the record
                    obj.fileReader.AdvanceThroughFile(-1);

                case 13
                    % A binary dump record is written as follows:
                    % byte 1 - 13 (binary dump item identifier)
                    % bytes 2 and 3 - block type (0000, main eeprom 8K, 0001 module settings eeprom dump 8K, 0002 ADAS lane dumpe 132K)
                    % byte 4 - length of binary dump name (7 bit encoded)
                    % n bytes - binary dump name
                    % n + 1 - data type
                    % n + 2 - length of data block
                    % m bytes - data

                    %---------------------------------------------%

                    % We've already read the first byte in order to have gotten to this point
                    % so we're reading the block type
                    binDump_BlockType = obj.ReadPrimitive('uint16', 2);

                    % When parsing VBB strings, the parser function looks for the
                    % bytes that represent the length of that string. So we don't
                    % need to manually look for the string length
                    binDump_Name = obj.ParseVBBValue('string');

                    % Parse the next byte to find out what type of object this
                    % dimary dump is - it should be a byte array
                    binDump_ValueTypeByte = obj.ReadPrimitive('uint8', 1);
                    binDump_ValueType = F_parse_vbb_valueType(binDump_ValueTypeByte);

                    % Read the binary dump item itself
                    binDump_Value = obj.ParseVBBValue(binDump_ValueType);


                    % Add this new entry to the Binary Dump
                    binDump_NewStruct = struct('name', binDump_Name, ...
                                               'value', binDump_Value, ...
                                               'valueType', binDump_ValueType, ...
                                               'blockType', binDump_BlockType);
                    obj.vbbFile.binaryDump(end + 1) = binDump_NewStruct;

                otherwise
                    % We have an unexpected VBB record header type. Set the
                    % file reader to the end of the file and only read the
                    % data up to this point
                    fprintf('This file contains an unexpected VBB record type %d. No data will be loaded past this point.\n', vbbRecordID);
                    
                    % Advance the file reader to the end of the file
                    obj.fileReader.AdvanceThroughFile(obj.fileReader.fileArrayLength);
            end
        end



        %% Data type parsing functions

        % These functions are used to parse individual data types out of a VBB file. 
        % These include primitive types (uint8, int64, etc..) as well as
        % custom VBB data types (datetime, 7 bit encoded string, etc...)


        function [parsedValue, isEoF] = ParseVBBValue(obj, vbbValueType)
            % The input data_type should be used in conjunction with
            % F_parse_vbb_valueType. All possible outputs of that function are
            % accounted for in this function.
            %
            % The input variables are as such:
            % VBBFileReader - this is a VBBFileReader object which should have the full VBB file byte array in memory
            % vbbValueType - the type of data you want to read out of the binary file. E.g. uint8, int32...

            %---------------------------------------------%

            % Extract and parse the data from the file
            switch vbbValueType
                case 'none'
                    return;
                case {'uint8', 'int8'}
                    [parsedValue, isEoF] = obj.ReadPrimitive(vbbValueType, 1);
                case {'uint16', 'int16'}
                    [parsedValue, isEoF] = obj.ReadPrimitive(vbbValueType, 2);
                case {'uint32', 'int32', 'single'}
                    [parsedValue, isEoF] = obj.ReadPrimitive(vbbValueType, 4);
                case {'uint64', 'int64', 'double'}
                    [parsedValue, isEoF] = obj.ReadPrimitive(vbbValueType, 8);
                case 'time'
                    [parsedValue, isEoF] = obj.ReadPrimitive('int32', 4);
                case 'datetime'
                    [parsedValue, isEoF] = obj.ReadVBBDatetime();
                case 'string'
                    [parsedValue, isEoF] = obj.ReadVBBString();
                case 'byteArray'
                    [parsedValue, isEoF] = obj.ReadVBBByteArray();
                otherwise
                    error('Unsupported data type - %s', vbbValueType);
            end

        end


        function [readValue, isEoF] = ReadPrimitive(obj, dataType, n_bytes)
            % This function will read primitve values out of the byte
            % array. It casts them to the correct type and makes sure to
            % account for the endianness of the file

            %---------------------------------------------%

            [bytes, isEoF] = obj.fileReader.ReadBytes(n_bytes);

            % Because we're using matlab's typecast function,
            % it will assume the byte stream was read in the same format as the
            % system. So if the computer is little endian it will try combining the
            % bytes as if they've been read from a little endian file. Thus we need
            % to flip the byte array to match the endianness of the computer this
            % code is being run on.
            if obj.endiannessMatch == 0
                bytes = bytes(end:-1:1);  % Reverses the byte order
            end

            % Cast the byte array into the correct type
            readValue = typecast(bytes, dataType);
        end


        function [parsedDatetime, isEoF] = ReadVBBDatetime(obj)
            % This function takes a VBB file that has had the headers read into
            % memory and, based on the Format Version that's been read, will extract
            % the datetime from the next 8 bytes.

            %---------------------------------------------%

            if obj.formatVersion == 1

                % In Format Version v1 the time data is stored as
                % year, month, day, hours, minutes, seconds

                year = obj.ReadPrimitive('uint16', 2);
                month = obj.ReadPrimitive('uint8', 1);
                day = obj.ReadPrimitive('uint8', 1);
                hour = obj.ReadPrimitive('uint8', 1);
                minute = obj.ReadPrimitive('uint8', 1);
                [second, isEoF] = obj.ReadPrimitive('uint8', 1);

                parsedDatetime = datetime(year, month, day, hour, minute, second);

            elseif obj.formatVersion == 2

                % In Format Version v2 the time data is stored in ticks - 100ns
                % increments since 01-01-0001

                [rawTimeValue, isEoF] = obj.ReadPrimitive('uint64', 8);
                mask = uint64(0x3FFFFFFFFFFFFFFF);
                ticks = int64(bitand(rawTimeValue, mask));

                % 1 tick = 100 nanoseconds, therefore 1 second = 10^7 ticks
                % 1 day = 24 * 60 * 60 seconds = 86400 seconds
                seconds = double(ticks) / 1e7;
                days = seconds / 86400;

                % VBB datetime base is 0001-01-01, MATLAB datetime base is 0000-01-00
                % Add the necessary offset of 366 days for the leap year and 1 day
                % for the 00 to 01 offset.
                parsedDatetime = datetime(days + 367, 'ConvertFrom', 'datenum');

                % Set the time of day using the number of seconds
                %
                % Divide the total number of seconds by the number of seconds in a
                % day. The remainder is the number of seconds elapsed today
                secondsToday = mod(seconds, 86400);
                % Use the number of seconds that have elapsed today to determine
                % the hours/minutes/seconds of the current tick value
                parsedDatetime.Hour = floor(secondsToday / 3600);
                parsedDatetime.Minute = floor(mod(secondsToday, 3600) / 60);
                parsedDatetime.Second = mod(secondsToday, 60);

                % Supress warnings that occur because our bit mask is large
                warning('off', 'MATLAB:hex2dec:InputExceedsFlintmax');

                % Determine the DateTimeKind based on the upper two bits
                if bitand(rawTimeValue, uint64(hex2dec('0xC000000000000000'))) == uint64(hex2dec('0x8000000000000000'))
                    parsedDatetime.TimeZone = 'local';  % Adjust this according to your local machine's time zone
                elseif bitand(rawTimeValue, uint64(hex2dec('0xC000000000000000'))) == uint64(0)
                    parsedDatetime.TimeZone = 'UTC';
                else
                    parsedDatetime.TimeZone = '';  % Unspecified or floating
                end

                warning('on', 'MATLAB:hex2dec:InputExceedsFlintmax');

            else
                error('Unsupported VBB file Format - %s', fileFormatVersion);
            end

        end


        function [parsedString, isEoF] = ReadVBBString(obj)
            % This function reads a variable length string from a VBB file.
            % Strings are stored in VBB files as <length><string data>
            %   length - a 7bit encoded integer and is the total number of bytes
            %            used to encode the string (NOT the string length)
            %   string data - a UTF-8 encoded string

            %---------------------------------------------%

            % Read out the byte array by decoding the array length from the first
            % byte
            [string_as_bytes, isEoF] = obj.ReadVBBByteArray();

            % Reverses the byte order for little endian files
            if obj.fileEndianness == 'L'
                string_as_bytes = string_as_bytes(end:-1:1);
            end

            % Turn the byte array into a character array, then into a string.
            % We have to transpose the byte array into a column vector for the
            % MATLAB char function to work
            parsedString = native2unicode(string_as_bytes, 'UTF-8');
        end


        function [parsedVBBByteArray, isEoF] = ReadVBBByteArray(obj)
            % This function reads a vbb byte array from a vbb file and puts it in
            % the correct order based on the endianness of the file.
            %
            % Byte arrays are stored as <length><bytes>
            %   length - a 7bit encoded integer and is the total number of bytes
            %            used to encode the string (NOT the string length)
            %   bytes - the byte data
            %
            % fileID - the first output when calling fopen() on a VBB file
            % fileEndianness - a string representing the endianness of the file. 'B' or 'L'

            %---------------------------------------------%

            byteArray_size = obj.Read7BitEncodedInt();

            % Now use fread() to extract the bytes corresponding to the array
            [parsedVBBByteArray, isEoF] = obj.fileReader.ReadBytes(byteArray_size);

            % Reverses the byte order for little endian files
            if obj.fileEndianness == 'L'
                parsedVBBByteArray = parsedVBBByteArray(end:-1:1);
            end

            return;
        end


        function [encodedIntValue, isEoF] = Read7BitEncodedInt(obj)

            % Use the endianness of the file to correctly parse the 7-bit encoded
            % string length from the first byte
            switch obj.fileEndianness
                case 'B'
                    integer = int32(0);
                    while true
                        [temp, isEoF] = obj.fileReader.ReadBytes(1);
                        temp = int32(temp);
                        integer = bitshift(integer, 7);
                        integer = integer + bitand(temp, int32(0x7F));

                        % Mask the first bit in the byte, if it's not set then
                        % there are no other bytes to read for the int
                        if bitand(temp, int32(0x80)) ~= 0x80
                            break;
                        end
                    end
                    encodedIntValue = integer;
                case 'L'
                    encodedIntValue = 0;
                    shift = 0;
                    while true
                        [byte, isEoF] = obj.fileReader.ReadBytes(1);
                        byte = int32(byte);
                        encodedIntValue = encodedIntValue + bitshift(bitand(byte, int32(0x7F)), shift);

                        % Mask the first bit in the byte, if it's not set then
                        % there are no other bytes to read for the int
                        if bitand(byte, int32(0x80)) ~= 0x80
                            break;
                        end
                        shift = shift + 7;
                    end
                otherwise
                    error('Unsupported endianness - %s', obj.fileEndianness);
            end
        end


    end
end

