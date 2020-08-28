-- About PrimoVE.lua
--
-- version 3.0 sends API lending request, as NCIP requests could not target a barcode

-- Updated for ULS by Jason Thorhauer jat188@pitt.edu
-- Updated for Primo VE by Mark Sullivan, IDS Project, Mark@idsproject.org
-- Author: Bill Jones III, SUNY Geneseo, IDS Project, jonesw@geneseo.edu
-- PrimoVE.lua provides a basic search for ISBN, ISSN, Title, and Phrase Searching for the Primo VE interface.
-- There is a config file that is associated with this Addon that needs to be set up in order for the Addon to work.
-- Please see the ReadMe.txt file for example configuration values that you can pull from your Primo New UI URL.
--
-- set AutoSearchISxN to true if you would like the Addon to automatically search for the ISxN.
-- set AutoSearchTitle to true if you would like the Addon to automatically search for the Title.

local settings = {};
settings.AutoSearchISxN = GetSetting("AutoSearchISxN");
settings.AutoSearchOCLC = GetSetting("AutoSearchOCLC");
settings.AutoSearchTitle = GetSetting("AutoSearchTitle");
settings.PrimoVEURL = GetSetting("PrimoVEURL");
settings.BaseVEURL = GetSetting("BaseVEURL");
settings.AlmaBaseURL = GetSetting("AlmaBaseURL");
settings.DatabaseName = GetSetting("DatabaseName");
settings.AgencyID = GetSetting("AgencyID");
settings.ApplicationProfileType = GetSetting("ApplicationProfileType");
settings.APIEndpoint = GetSetting("API_Endpoint");
settings.APIkey = GetSetting("APIKey");

luanet.load_assembly("System.Windows.Forms");

require "Atlas.AtlasHelpers";

-- Load the log4net assembly
luanet.load_assembly("log4net");
luanet.load_assembly("System");
luanet.load_assembly("System.Net");
luanet.load_assembly("System.IO");


local types = {};

types["System.Windows.Forms.Shortcut"] = luanet.import_type("System.Windows.Forms.Shortcut");

local interfaceMngr = nil;
local PrimoVEForm = {};
local SRUQueryForm = {};
local ReportIssueForm = {};

PrimoVEForm.Form = nil;
PrimoVEForm.Browser = nil;

ReportIssueForm.Form = nil;
ReportIssueForm.Browser = nil;

SRUQueryForm.Form = nil;
SRUQueryForm.Browser = nil;
local watcherEnabled = false;

PrimoVEForm.RibbonPage = nil;

function Init()
    -- The line below makes this Addon work on all request types.
    if GetFieldValue("Transaction", "RequestType") ~= "" then
    interfaceMngr = GetInterfaceManager();

    -- Create browser
    PrimoVEForm.Form = interfaceMngr:CreateForm("PrimoVE", "Script");
    PrimoVEForm.Browser = PrimoVEForm.Form:CreateBrowser("PrimoVE", "PrimoVE", "PrimoVE");

    -- Hide the text labels
    PrimoVEForm.Browser.TextVisible = false;

    --Suppress Javascript errors
    PrimoVEForm.Browser.WebBrowser.ScriptErrorsSuppressed = true;

    -- Since we didn't create a ribbon explicitly before creating our browser, it will have created one using the name we passed the CreateBrowser method. We can retrieve that one and add our buttons to it.
    PrimoVEForm.RibbonPage = PrimoVEForm.Form:GetRibbonPage("PrimoVE");
    -- The GetClientImage("Search32") pulls in the magnifying glass icon. There are other icons that can be used.
	-- Here we are adding a new button to the ribbon
	PrimoVEForm.RibbonPage:CreateButton("Search Title", GetClientImage("Search32"), "SearchTitle", "Search PrimoVE");
	PrimoVEForm.RibbonPage:CreateButton("Search ISxN", GetClientImage("Search32"), "SearchISxN", "Search PrimoVE");
	PrimoVEForm.RibbonPage:CreateButton("Search OCLC#", GetClientImage("Search32"), "SearchOCLC", "Search PrimoVE");
	PrimoVEForm.ImportButton = PrimoVEForm.RibbonPage:CreateButton("Select a single PrimoVE location first", GetClientImage("Search32"), "ImportAndUpdateRecord", "Update Record");
	PrimoVEForm.RequestButton = PrimoVEForm.RibbonPage:CreateButton("Request item from holding library", GetClientImage("ImportData32"), "RequestItem", "Request Item via API");
	PrimoVEForm.ReportIssueButton = PrimoVEForm.RibbonPage:CreateButton("Report catalog problem", GetClientImage("Alarm32"), "ReportIssue", "Report Catalog Error");
	
	
	--feature not yet implemented
	PrimoVEForm.ReportIssueButton.BarButton.Enabled = false;
	
	
    PrimoVEForm.Form:Show();
    end
		
	if settings.AutoSearchISxN then
		SearchISxN();
	elseif settings.AutoSearchOCLC then
		SearchOCLC();
	elseif settings.AutoSearchTitle then
		SearchTitle();
	else 
		DefaultURL();
	end
	
		PrimoVEForm.ImportButton.BarButton.Enabled = false;
		
		local MMSID = GetFieldValue("Transaction","ReferenceNumber");
		
		-- LUA empty strings are NOT nil!
		if (MMSID == '') then
			PrimoVEForm.RequestButton.BarButton.Enabled = false;
		else
			PrimoVEForm.RequestButton.BarButton.Enabled = true;
		end

end


function SRU()
-- Send item barcode to SRU endpoint, parse DublinCore response, verify that NumberOfRecords == 1, use RecordIdentifier as MMS_ID


itembarcode = GetFieldValue("Transaction", "ItemNumber");
local SRUendpoint = settings.AlmaBaseURL .. 'view/sru/' .. settings.AgencyId .. '?version=1.2&operation=searchRetrieve&recordSchema=dc&query=alma.barcode=' .. itembarcode
LogDebug("Querying SRU for barcode"..itembarcode);

luanet.load_assembly("System");

local SRUWebClient = luanet.import_type("System.Net.WebClient");
local streamreader = luanet.import_type("System.Net.IO.StreamReader");
local ThisWebClient = SRUWebClient();
LogDebug("SRU Webclient Created");

local SRUResults = ThisWebClient:DownloadString(SRUendpoint);

local NumberOfRecords = SRUResults:match("numberOfRecords>(.-)<");
LogDebug(NumberOfRecords.." SRU results for barcode "..itembarcode);

if (NumberOfRecords == '1') then
	local MMSID = SRUResults:match("recordIdentifier>(.-)<");
	LogDebug('Writing MMS_ID '.. MMSID ..' to ReferenceNumber field');
	SetFieldValue("Transaction", "ReferenceNumber", MMSID);
end

end


function ReportIssue()
-- This feature is not yet active, but should allow ILL practitioners to report catalog issues via SpringShare queues
-- ReportIssueForm.Form = interfaceMngr:CreateForm("ReportIssue", "Script");
-- ReportIssueForm.Browser = ReportIssueForm.Form:CreateBrowser("Report an issue", "Report an Issue", "ReportIssue");
-- local currenturl = tostring(PrimoVEForm.Browser.WebBrowser.Url);
ReportIssueForm.Form:Show();

	
end


function RequestItem()
-- Alma RequestItem API calls work with both bibliographic IDs and barcodes!.  This is much more useful than NCIP-based bibliographic-only requests!
local tn = tonumber(GetFieldValue("Transaction", "TransactionNumber"));
local barcode = GetFieldValue("Transaction","ItemNumber");
local MMSID = GetFieldValue("Transaction","ReferenceNumber");

-- LUA empty strings are NOT nil!
if barcode == '' then
	interfaceMngr:ShowMessage("No barcode saved in record - please verify barcode","No barcode");
	ExecuteCommand("SwitchTab", {"Detail"});
	return;
elseif (MMSID == '') then
	-- call function to perform MMS_ID lookup from barcode
	SRU();
	MMSID = GetFieldValue("Transaction","ReferenceNumber");
end


LogDebug("Building Lending Request API XML for MMS_ID "..MMSID.." and barcode "..barcode);

-- reverify that the MMS_ID exists before attempting to submit request
if (MMSID ~= '') then					
	
		local dr = tostring(GetFieldValue("Transaction", "DueDate"));
		local df = string.match(dr, "%d+\/%d+\/%d+");
		local mn, dy, yr = string.match(df, "(%d+)/(%d+)/(%d+)");
		local mnt = string.format("%02d",mn);
		local dya = string.format("%02d",dy);
		local LRAPImessage = '';
		LRAPImessage = LRAPImessage .. '<?xml version="1.0" encoding="UTF-8"?>'
		LRAPImessage = LRAPImessage .. '<user_resource_sharing_request>'	
		LRAPImessage = LRAPImessage .. '<external_id>' .. tn .. '</external_id>'
		LRAPImessage = LRAPImessage .. '<partner>' .. settings.ApplicationProfileType .. '</partner>'
		LRAPImessage = LRAPImessage .. '<owner>RES_SHARE</owner>' 
		LRAPImessage = LRAPImessage .. '<requested_media>1</requested_media>'
		LRAPImessage = LRAPImessage .. '<format>PHYSICAL</format>'
		LRAPImessage = LRAPImessage .. '<note>ILLiad TN ' .. tn .. '</note>' 
		LRAPImessage = LRAPImessage .. '<mms_id>' .. MMSID .. '</mms_id>'
		LRAPImessage = LRAPImessage .. '<barcode>' .. barcode ..'</barcode>'
		LRAPImessage = LRAPImessage .. '<citation_type desc="string">'
		LRAPImessage = LRAPImessage .. '<xml_value>BOOK</xml_value>'
		LRAPImessage = LRAPImessage .. '</citation_type>'
		LRAPImessage = LRAPImessage .. '</user_resource_sharing_request>'
	
		
		--[[
		This is what a functional API request message looks like:
		<?xml version="1.0" encoding="UTF-8"?>
		<user_resource_sharing_request>
		<external_id>JPTTEST08132020</external_id>
		<partner>ULS_ILLIAD</partner>
		<owner>RES_SHARE</owner>
		<requested_media>1</requested_media>
		<format>PHYSICAL</format>
		<note>This is a note added to the request</note>
		<mms_id>9941969813406236</mms_id>
		<barcode>31735049669280</barcode>
		<citation_type desc="string"> 
		<xml_value>BOOK</xml_value> 
		</citation_type>
		</user_resource_sharing_request>
		]]--
		
		LogDebug("Sending Lending Request to holding library: "..LRAPImessage);
		ExecuteCommand("AddHistory", {tn, 'LendingRequest API xml sent', 'System'})
		
		local APIAddress = settings.APIEndpoint .. "?apikey=" .. settings.APIKey;
		luanet.load_assembly("System");
		local WebClient = luanet.import_type("System.Net.WebClient");
		local LRWebClient = WebClient();
		LogDebug("WebClient Created");
		LogDebug("Adding Header");
		
		LRWebClient.Headers:Add("Content-Type", "application/xml;charset=UTF-8");
		local LRresponseArray = LRWebClient:UploadString(APIAddress, LRAPImessage);
		LogDebug("Upload response was[" .. LRresponseArray .. "]");
			
		--Move to failure queue if API fails
		--Alma currently permits NCIP requests for nonexistent MMS_IDs it isn't possible to do a lot of trapping or validation here
		--APIs provide slightly more flexibility, so it should be possible to parse out XML response LRresponseArray and show details of <Error Message> as a TN History entry if <errorsExist> is TRUE
		--Failed requests should be routed to the failure queue for later intervention
		--ExecuteCommand("Route", {tn, "API Error: LendingRequestItem Failed"});
		
		--There could be a popup here confirming that the request was sent to prevent ILL practitioners from clicking it multiple times
		
		ExecuteCommand("SwitchTab", {"Detail"});
		
		--ExecuteCommand("Save");
end --don't bother running if MMS_ID is not located in ReferenceNumber field


end

function DefaultURL()
		InitializePageHandler();
		PrimoVEForm.Browser:Navigate(settings.PrimoVEURL);
end

-- This function searches for ISxN for both Loan and Article requests.
function SearchISxN()
	InitializePageHandler();
    if GetFieldValue("Transaction", "ISSN") ~= "" then
		PrimoVEForm.Browser:Navigate(settings.BaseVEURL .. "/discovery/search?query=any,contains," .. GetFieldValue("Transaction", "ISSN") .. "&tab=LibraryCatalog&search_scope=MyInstitution&sortby=rank&vid=" .. settings.DatabaseName .. "&lang=en_US&offset=0");
	else
		interfaceMngr:ShowMessage("ISxN is not available from request form", "Insufficient Information");
	end
end

function SearchOCLC()
	InitializePageHandler();
    if GetFieldValue("Transaction", "ESPNumber") ~= "" then
		PrimoVEForm.Browser:Navigate(settings.BaseVEURL .. "/discovery/search?query=any,contains," .. GetFieldValue("Transaction", "ESPNumber") .. "&tab=LibraryCatalog&search_scope=MyInstitution&sortby=rank&vid=" .. settings.DatabaseName .. "&lang=en_US&offset=0");
	else
		interfaceMngr:ShowMessage("OCLC# is not available from request form", "Insufficient Information");
	end
end


-- This function performs a standard search for LoanTitle for Loan requests and PhotoJournalTitle for Article requests.
function SearchTitle()
	InitializePageHandler();
    if GetFieldValue("Transaction", "RequestType") == "Loan" then  
		PrimoVEForm.Browser:Navigate(settings.BaseVEURL .. "/discovery/search?query=any,contains," ..  GetFieldValue("Transaction", "LoanTitle") .. "&tab=LibraryCatalog&search_scope=MyInstitution&sortby=rank&vid=" .. settings.DatabaseName .. "&lang=en_US&offset=0");
	elseif GetFieldValue("Transaction", "RequestType") == "Article" then  
		PrimoVEForm.Browser:Navigate(settings.BaseVEURL .. "/discovery/search?query=any,contains," .. GetFieldValue("Transaction", "PhotoJournalTitle") .. "&tab=LibraryCatalog&search_scope=MyInstitution&sortby=rank&vid=" .. settings.DatabaseName .. "&lang=en_US&offset=0");
	else
		interfaceMngr:ShowMessage("The Title is not available from request form", "Insufficient Information");
	end
end


function CheckPage()
-- checks to verify that a single record has been selected, but don't bother doing a deep dive unless the URL looks like a discovery result
local IsRecordExpanded = false;
local MagicSpanPresent = false;
local currenturl = tostring(PrimoVEForm.Browser.WebBrowser.Url);

if currenturl:find("^" .. settings.BaseVEURL .. "/discovery/fulldisplay?") then
	local spanElements = PrimoVEForm.Browser.WebBrowser.Document:GetElementsByTagName("span");

	for i=0, spanElements.Count - 1 do
		spanElement = PrimoVEForm.Browser:GetElementByCollectionIndex(spanElements, i);
		if spanElement.InnerText == "Back to locations" then
		MagicSpanPresent = true;
		
		end
	end
else MagicSpanPresent = false;
end

if MagicSpanPresent then
		-- We found a SPAN that indicates a single record was selected.   Expand holdings info and enable the Import and Request buttons.

		
		if (IsRecordExpanded == false) then
			
			local buttonarray = PrimoVEForm.Browser.WebBrowser.Document:GetElementsByTagName("button");
			
			--ESCAPE QUOTES WITH \
			--ESCAPE ( ) . % + - * ? [ ^ $ with %
			-- we need to look for button that contains aria-label="Expand/Collapse item"
			
			buttonmatchpattern = "aria%-label=\"Expand/Collapse item\""
			for j=0, buttonarray.Count -1 do
			
				button = PrimoVEForm.Browser:GetElementByCollectionIndex(buttonarray, j);

				if (button.outerHTML:find(buttonmatchpattern) ~= nil) then
					PrimoVEForm.Browser:ClickObjectByReference(button);
					IsRecordExpanded = true;
					break;
				end
			end

		end
		
		PrimoVEForm.ImportButton.BarButton.Caption = "Import call number, location, and barcode";
		PrimoVEForm.ImportButton.BarButton.Enabled = true;
		PrimoVEForm.RequestButton.BarButton.Enabled = true;
		
		StopPageWatcher();
	else
		-- We didn't find the SPAN we're looking for on this page, so keep waiting
		StartPageWatcher();
		PrimoVEForm.ImportButton.BarButton.Caption = "Select a single PrimoVE location first";
		PrimoVEForm.ImportButton.BarButton.Enabled = false;
		
	
		
end

return MagicSpanPresent

end

function StartPageWatcher()
    watcherEnabled = true;
    local checkIntervalMilliseconds = 3000; -- 3 seconds
    local maxWatchTimeMilliseconds = 600000; -- 10 minutes
    PrimoVEForm.Browser:StartPageWatcher(checkIntervalMilliseconds, maxWatchTimeMilliseconds);
	local barcode = GetFieldValue("Transaction","ItemNumber");
	
	if (barcode ~= '') then
	PrimoVEForm.RequestButton.BarButton.Enabled = true;
	end
	
end

function StopPageWatcher()
    if watcherEnabled then
        PrimoVEForm.Browser:StopPageWatcher();
    end

    watcherEnabled = false;
end

function InitializePageHandler()
    PrimoVEForm.Browser:RegisterPageHandler("custom", "CheckPage", "PageHandler", false);
end


function PageHandler()
InitializePageHandler();
end

function ImportAndUpdateRecord()

local tagElements = PrimoVEForm.Browser.WebBrowser.Document:GetElementsByTagName("prm-location-items");

local status = {} ;
local library = {} ;
local location = {} ;
local callnumber = {} ;



--[[ MATCH STRINGS
Item status
<span class="availability-status available" translate="fulldisplay.availabilty.available">

Item location
<h4 class="md-title ng-binding zero-margin" ng-if="$ctrl.currLoc.location &amp;&amp; $ctrl.getLibraryName($ctrl.currLoc.location)">

Library
<span ng-if="$ctrl.currLoc.location &amp;&amp; $ctrl.currLoc.location.subLocation &amp;&amp; $ctrl.getSubLibraryName($ctrl.currLoc.location)" ng-bind-html="$ctrl.currLoc.location.collectionTranslation">

Call number
<span dir="auto" ng-if="$ctrl.currLoc.location.callNumber">


ESCAPE QUOTES WITH \
ESCAPE ( ) . % + - * ? [ ^ $ with %

[SIC] fulldisplay.availbilty.available is not spelled correctly because PrimoVE spells the class this way
<span class=\"availability%-status available\" translate=\"fulldisplay%.availabilty%.available\">
<h4 class=\"md%-title ng%-binding zero%-margin\" ng%-if=\"%$ctrl%.currLoc%.location &amp;&amp; %$ctrl%.getLibraryName%(%$ctrl%.currLoc%.location%)\">
<span ng%-if=\"%$ctrl%.currLoc%.location &amp;&amp; %$ctrl%.currLoc%.location%.subLocation &amp;&amp; %$ctrl%.getSubLibraryName%(%$ctrl%.currLoc%.location%)\" ng%-bind%-html=\"%$ctrl%.currLoc%.location%.collectionTranslation\">
<span dir=\"auto\" ng%-if=\"%$ctrl%.currLoc%.location%.callNumber\">


--]]
		if tagElements ~= nil then
			PrimoVEForm.ImportButton.BarButton.Enabled = true;
			PrimoVEForm.RequestButton.BarButton.Enabled = true;

			local pElements = PrimoVEForm.Browser.WebBrowser.Document:GetElementsByTagName("p");	
			if pElements ~=nil then
				for k=0, pElements.Count - 1 do
					outerHTMLstring = pElements[k].outerHTML
					if outerHTMLstring:match("<p>Barcode: (.-)</p>") then
						barcode = outerHTMLstring:match("<p>Barcode: (.-)</p>")
						SetFieldValue("Transaction", "ItemNumber", barcode);
					end
				
				end
			end
				

				
			for j=0, tagElements.Count - 1 do
				divElement = PrimoVEForm.Browser:GetElementByCollectionIndex(tagElements, j);
					
					innerhtmlstring = divElement.innerHTML;
		
					status[j] = innerhtmlstring:match("<span class=\"availability%-status available\" translate=\"fulldisplay%.availabilty%.available\">(.-)<");
					library[j] = innerhtmlstring:match("<h4 class=\"md%-title ng%-binding zero%-margin\" ng%-if=\"%$ctrl%.currLoc%.location &amp;&amp; %$ctrl%.getLibraryName%(%$ctrl%.currLoc%.location%)\">(.-)<");
					location[j] = innerhtmlstring:match("<span ng%-if=\"%$ctrl%.currLoc%.location &amp;&amp; %$ctrl%.currLoc%.location%.subLocation &amp;&amp; %$ctrl%.getSubLibraryName%(%$ctrl%.currLoc%.location%)\" ng%-bind%-html=\"%$ctrl%.currLoc%.location%.collectionTranslation\">(.-)<");
					callnumber[j]= innerhtmlstring:match("<span dir=\"auto\" ng%-if=\"%$ctrl%.currLoc%.location%.callNumber\">(.-)<");
					
					if callnumber[j] ~= nil then
					SetFieldValue("Transaction", "CallNumber", callnumber[j]);
					end
					
					if ((library[j] ~= nil) and (location[j] ~= nil)) then
					SetFieldValue("Transaction", "Location", library[j].." "..location[j]);
					end
								
			end
		--ExecuteCommand("Save");
		
		else
		PrimoVEForm.ImportButton.BarButton.Enabled = false;
		if (MMSID == '') then
			PrimoVEForm.RequestButton.BarButton.Enabled = false;
		end
		
		end
		
end
