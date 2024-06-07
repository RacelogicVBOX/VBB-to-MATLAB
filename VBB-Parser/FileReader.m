classdef FileReader < handle
    % This class is in charge of managing a binary file. It reads the whole
    % file into a uint8 array, then allows access via indexing.
    %
    % We use this as it is faster than calling fread() every time we want
    % to get data out of a file

    properties

        % This is how long a data section should be (100Mb)
        chunkLength = 10e7;
        % This is how many bytes are left to read from the file
        remainingBytes = 0;

        % This is the array of binary data from a section of the file
        sectionArray;
        % This is the total number of bytes in the section
        sectionLength = 0;
        % This is the current read position in the file section
        sectionIndex = 1;
        % This is a buffer, if we try to read bytes that are within this
        % buffer distance from the end of the section we flag it. This
        % should be set to be the length of the largest sample group. This
        % ensures that we can always read a full sample group before the
        % end of a section
        sectionBufferLength = 100;


        % This is the length of the entire file
        overallLength = 0;
        % This is the index we're currently up to the in the entire file
        overallIndex = 1;

        % This is the ID of the file
        fileID;

    end

    methods

        function obj = FileReader(filePath)

            % Open the file (if it exists)
            [obj.fileID, errmsg] = fopen(filePath, 'rb');
            if obj.fileID < 0
                error('Filed to open file: %s', errmsg)
            end

            % Work out the full size of the file
            fseek(obj.fileID, 0, 'eof');
            obj.overallLength = ftell(obj.fileID);
            % Move back to the start of the file
            fseek(obj.fileID, 0, 'bof');
            

            obj.sectionArray = [];
            obj.sectionLength = 0;
            obj.sectionIndex = 1;
            obj.overallIndex = 1;
            obj.remainingBytes = obj.overallLength;

            % Read in the first section into memory
            obj.ReadNextSection();

            % % Read the entire file into memory
            % obj.sectionArray = uint8(fread(fileID, 'uint8'));
            % obj.sectionLength = length(obj.sectionArray);
            % obj.sectionIndex = 1;
            % 
            % fclose(fileID);
        end

        
        function CloseFile(obj)
            % Used to make sure the file is closed once we've read it

            fclose(obj.fileID);
        end


        function isEoF = ReadNextSection(obj)
            % This function reads the next section from the file. If we're
            % not at the end of the current section then we include any
            % remaining bytes. If the next section would go over the end of
            % the file then we just return the remaining bytes and flag
            % that we're at the end of the file
 
            % Make sure that we haven't read over the end of the file
            if obj.overallIndex > obj.overallLength
                isEoF = true;
                return;
            end

            % Calculate how many bytes are remaining in the current section
            remainingInSection = obj.sectionLength - obj.sectionIndex + 1;
            
            % Calculate the number of bytes to read - if a chunk would read
            % past the end then just read whatever is left
            bytesToRead = min(obj.chunkLength - remainingInSection, obj.remainingBytes);

            % Read the next section
            additionalBytes = uint8(fread(obj.fileID, bytesToRead, 'uint8'));
            
            % Remove the read bytes from the current array
            obj.sectionArray = obj.sectionArray(obj.sectionIndex:end);
            % Add the new bytes
            obj.sectionArray = [obj.sectionArray; additionalBytes];

            % Update the section length and index
            obj.sectionLength = length(obj.sectionArray);
            obj.sectionIndex = 1;

            % Update the overall file index
            obj.overallIndex = obj.overallIndex - remainingInSection + obj.sectionLength;

            % Determine if this is the end of the file
            isEoF = obj.overallIndex > obj.overallLength;


            % Update how many bytes are remaining to be read
            obj.remainingBytes = obj.overallLength - obj.overallIndex + 1;
        end


        function [bytes, isEoS] = ReadBytes(obj, numBytes)
            % Read the requested number of bytes out of the file array. If
            % the requested amount of bytes takes us over the end of the
            % section then just return all the remaining bytes

            % isEoS stands for 'is end of section'
            %---------------------------------------------%

            isEoS = false;
            
            endIndex = obj.sectionIndex + numBytes - 1;

            % A warning is raised if we're within the buffer zone at the
            % end of a data section
            if endIndex >= obj.sectionLength - obj.sectionBufferLength
                
                isEoS = true;
                
                % Check to make sure we don't go over the end of the array.
                % If we would, set the end index to it's max value
                if endIndex >= obj.sectionLength
                    endIndex = obj.sectionLength;
                end
            end

            % Read out the requested bytes into the output array
            bytes = obj.sectionArray(obj.sectionIndex:endIndex);
            % Set the current position in the file to be 1 byte on from where we've just read
            obj.sectionIndex = endIndex + 1;
        end


        function result = AdvanceThroughFile(obj, steps)
            % This will advance the currentIndex by the requested number of
            % steps. If this would result in going past either end of the
            % section we then cap the value.
            %
            % EoS = End of Section
            % SoS = Start of Section
            %---------------------------------------------%

            newIndex = obj.sectionIndex + steps;

            % Check that we don't go outside the bounds of the section
            if newIndex > obj.sectionLength
                obj.sectionIndex = obj.sectionLength;
                result = 'EoS';
            elseif newIndex <= 0
                obj.sectionIndex = 1;
                result = 'SoS';
            else
                obj.sectionIndex = newIndex;
                result = 'good';
            end

        end

    end
end

