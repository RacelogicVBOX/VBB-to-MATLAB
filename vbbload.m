clear;
format long g;

% Add the converter to path
addpath("VBB-Parser\");


%%              Reading a VBB file              %%

[filename,path] = uigetfile('*.vbb', 'Load VBB File');
% Check that the user has chosen a file
if (isequal(filename, 0))
	return;						
end

% Create the path to the VBB file
vbbPath = fullfile(path,filename);

% Instance a new VBBReader object
reader = VBBReader;
% Read the VBB file
vbbFile = reader.ReadVBBFile(vbbPath);

% Convert the VBBFile Object into something that matches the VBO-MATLAB output
% This isn't neccessary but is useful to avoid having to change existing
% code to work with VBB files.
simpleVBBFile = reader.CreateSimpleVBB();

fprintf('\n****Example Functions****\n');
fprintf('\nPlotting Brake Stop\n');
PlotSpeed(simpleVBBFile);
fprintf('\nCalculating latitude channel frequency:\n');
GetChannelFrequency(simpleVBBFile, 'latitude');

clear path vbbPath filename;



%%               Simple VBB Examples              %%

% These examples are designed to work with the example VBB file provided
% with this library.
%
% There are examples in how to find channels within a simpleVBBFile struct,
% how to find the frequency of a channel and how to make plots.


function [channel, frequencyGroup] = FindChannel(simpleVBBFile, channelName)
    % Arguments:
    % simpleVBBFile - a simpleVBBFile struct as output by VBBReader.m
    % channelName - a string
    %
    % Output:
    % channel - nx1 double array containing the data for the requested channel
    % frequencyGroup - a string for the frequency group this channel is in in the simpleVBBFile struct
    %
    % This function has duplicate code in it to demonstrate finding a
    % channel from a VBB if you don't know what frequency the channel was
    % recorded at, and if you do.

 
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    %  If you do know the frequency of the channel  %
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

    % Get the frequency group out of the simpleVBBFile
    frequencyGroup = 'channels_100Hz';
    channels = simpleVBBFile.(frequencyGroup);
    % Find the index of the longitude channel
    channelIndex = find(strcmp({channels.name}, channelName));

    % If the channel name is found, get the data out of the simpleVBBFile
    if (~isempty(channelIndex))
        channel = channels(channelIndex).data;
    end



    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    %  If you don't know the frequency of the channel  %
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

    % Loop over the different frequency groups
    frequencyGroups = fields(simpleVBBFile);

    for i = 1:length(frequencyGroups)
        % Get the frequency group struct. 'fields' returns a cell array, to
        % dynamically access the simpleVBBFile struct we need to convert each
        % entry from a 1x1 cell into a string
        frequencyGroup = string(frequencyGroups(i));
        channels = simpleVBBFile.(frequencyGroup);

        % Find the index of the channel of a given name in the frequency group.
        channelIndex = find(strcmp({channels.name}, channelName));

        % If the channel name is found, get the data out of the simpleVBBFile
        if (~isempty(channelIndex))
            channel = channels(channelIndex).data;
            return;
        else
            channel = [];
            frequencyGroup = "Channel_Not_Found";
        end
    end
end


function PlotSpeed(simpleVBBFile)
    % Input:
    % simpleVBBFile - a simpleVBBFile struct as output by VBBReader.m

    channelName = "velocity";
    [velocity, frequencyGroupName] = FindChannel(simpleVBBFile, channelName);
    % If a channel with this name does not exist then stop
    if (strcmp(frequencyGroupName, "Channel_Not_Found"))
        fprintf('"%s" channel not found', channelName);
        return;
    end

    % Get the list of channels in this frequency group
    channels = simpleVBBFile.(frequencyGroupName);
    % Find the index of the channel called 'time'
    timestampIndex = find(strcmp({channels.name}, 'time'));
    % Get the 'time' channel
    time = channels(timestampIndex).data;


    if (~isempty(velocity) && ~isempty(time))
        plot(time, velocity);
        title('Example VBB File: Brake Stop');
        xlabel('Time since midnight (s)');
        ylabel('Speed (km/h)');
    end

end


function GetChannelFrequency(simpleVBBFile, channelName)
    % Inputs:
    % simpleVBBFile - a simpleVBBFile struct as output by VBBReader.m
    % channelName - a string
    % 
    % Outputs:
    % frequency - a double
    %
    % This function demonstrates extracting a channel's frequency from a
    % simpleVBBFile struct name. It also shows the frequency being
    % calculated from the channel's timestamps to verify that the
    % simpleVBBFile struct is named correctly.


    % Use the output of FindChannel to get the name of the frequency group
    % in the simpleVBBFile
    [~, frequencyGroupName] = FindChannel(simpleVBBFile, channelName);
    
    % Get the list of channels in this frequency group
    channels = simpleVBBFile.(frequencyGroupName);
    % Find the index of the channel called 'time'
    timestampIndex = find(strcmp({channels.name}, 'time'));
    % Get the 'time' channel
    time = channels(timestampIndex).data;


    % Extract the channel frequency from the frequency group name in the
    % simpleVBBStruct. This can be done as the group name is
    % programatically set based on the calculated frequency of each channel
    channelFrequency = sscanf(frequencyGroupName, 'channels_%dHz');
    fprintf('"%s" frequency (from struct name) is %fHz\n', channelName, channelFrequency);

    % Calculate the frequency from the timestamp array. Subtract 2 adjacent
    % timestamps from one another to get the time between samples. Then
    % find the inverse. This can be averaged if you suspect there are
    % sample drops in the file. 
    % 
    % This is already done in order to get the frequency group name of the
    % simpleVBBFile but the process is repeated here for demonstration purposes.
    channelFrequency = length(time)/(time(end) - time(1));
    % Frequencies should be integers. So cast the result to one to remove
    % any rounding errors or missed samples
    channelFrequency = uint32(channelFrequency);
    fprintf('"%s" frequency (from timestamp array) is %fHz\n', channelName, channelFrequency);


end