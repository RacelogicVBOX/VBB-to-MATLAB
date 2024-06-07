classdef VBBFile < handle
    % This class holds information that is read from a VBB
    % file. It includes header information such as the Endianness and the 
    % format of the file.
    %
    % It inherits from handle so it acts like a reference type.
    

    properties
        
        % These are empty before the file is read
        fileCreated = NaT(0); % When the file was created
        fileLastModified = NaT(0); % When the file was last modified

        % Channel group definitions
        groupDefinitions = struct('groupID', {}, 'groupName', {});
        
        % System and setting information
        dictionary = struct('name', {}, 'value', {}, 'valueType', {}, 'groupID', {});
        
        % Holds information about the VBB channels stored in the file. The data section contains the channel data as read from the VBB
        % file. Each entry is timestamped. The scale and offset have been applied to the values in the Data array. This ensures the given
        % units are correct
        channelDefinitions = struct('channelID', {}, 'groupID', {}, 'shortName', {}, 'longName', {}, 'units', {}, 'valueType', {}, 'scale', {}, 'offset', {}, 'metaData', {}, 'timestamps', {}, 'data', {});
        
        % Holds information on the specific channel IDs contained within channel groups
        channelGroupDefinitions = struct('groupID', {}, 'numChannels', {}, 'channelIDs', {});
       
        % Holds the raw EEPROM data
        binaryDump = struct('name', {}, 'value', {}, 'valueType', {}, 'blockType', {});
    end  
end