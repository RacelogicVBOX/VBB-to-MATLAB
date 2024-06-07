#############################
   VBB to MATLAB converter
      2024 | Racelogic

#############################
        Requirements
#############################

Requires MATLAB version R2016b or higher.

Files larger than 2Gb are not recommended. Loading times are significantly
higher and soft locking may occur.

#############################
        Installation 
#############################

VBBReader.m, VBBFile.m, FileReader.m and F_parse_vbb_valueType.m need to 
be kept together. 

Add the VBB-Parser folder to your project and ensure it is added to the 
path.


#############################
           Usage
#############################

vbbload.m is a demo script showing how to use the converter.


Create a new instance of the VBBReader class then call .ReadVBBFile() with 
a string for the file path to the VBB file. The file will then be 
processed with some statements written to the console indicating progress. 
Once finished a VBBFile object will be returned. 

Calling .CreateSimpleVBB() on the VBBReader instance after reading a VBB 
file will output a 'Simple VBB file' struct. 

Example functions can be found in vbbload.m which show how to extract 
specific channels, find their frequency and plot them.


#############################
       Output Formats 
#############################

VBBFile - 
    This contains the full information extracted from a VBB file. It has a 
    channelDefinitions struct inside that has an entry for each channel 
    found. Each channel has a timestamp array along with its data array.
    These timestamp arrays are created using the timestamps found at the 
    start of each sample group. 

    Scale and offset are already applied to the channels so that the units
    of the values in the data array match the given units (these are used 
    when saving channels into a VBB file to minimise rounding errors).

SimpleVBBFile -  
    This struct mimics the structs created by the Racelogic VBO->MATLAB 
    converter. Because VBB channels can be logged at different frequencies, 
    we take each channel as extracted from the VBB, estimate its frequency, 
    then group same-frequency channels together. A group of channels in 
    the simple VBB struct can be assumed to be temporally aligned. 

    The VBO-MATLAB converter output a VBO struct that contained 'channels',
    which was itself a struct with 'name', 'units' and 'data' arrays. The 
    simpleVBBFile struct has the same format however, each same-frequency 
    grouping of channels is named 'channels_xHz' where x is the frequency 
    of that group.

    Each frequency group of channels contains a 'time' channel that is 
    the aligned timestamps for every channel in the group. This array is 
    created using the timestamps at the start of each sample group record 
    in the VBB and will not match the 'time' channel found in the VBB file.