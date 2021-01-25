-- About PrimoVE.lua
--
-- version 5.0 handles multipiece lending, using ILLiad transaction fields ItemInfo1 and ItemInfo2 to store delimited barcodes and Alma request IDs, respectively
-- Custom transaction fields ItemInfo1 and ItemInfo2 were not previously used by Pitt ULS, and are nvarchar(255).
-- A maximum of 15 pieces can be used with this method (16 digit Alma requestID plus delimiters)

-- version 4.0 sends API patron physical item request, as NCIP requests could not target a barcode

-- Updated for ULS by Jason Thorhauer jat188@pitt.edu
-- Uses API Patron Physical Item Request to transit items from holding libraries to Resource Sharing library (ILL office)

-- These are helpful development resources:
-- http://www.lua.org/manual/5.1/manual.html
-- https://atlas-sys.atlassian.net/wiki/spaces/ILLiadAddons/pages/3149440/Client+Addons



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
settings.AlmaBaseURL = GetSetting("AlmaBaseURL");
-- Add trailing slash to AlmaBaseURL if not present
lastChar = string.sub(settings.AlmaBaseURL, -1);
if (lastChar ~= "/") then 
	settings.AlmaBaseURL = settings.AlmaBaseURL .. "/"; 
end 

-- Add trailing slash to APIEndpoint if not present
settings.APIEndpoint = GetSetting("APIEndpoint");
lastChar = string.sub(settings.APIEndpoint, -1);
if (lastChar ~= "/") then 
	settings.APIEndpoint = settings.APIEndpoint .. "/"; 
end 

settings.DatabaseName = GetSetting("DatabaseName");
settings.AgencyID = GetSetting("AgencyID");
settings.ApplicationProfileType = GetSetting("ApplicationProfileType");
settings.PseudopatronCDS = GetSetting("PseudopatronCDS");

local DebugMode = GetSetting("DebugMode");
if (DebugMode==true) then
	settings.APIKey = GetSetting("SandboxAPIKey");
	settings.BaseVEURL = GetSetting("ProductionBaseVEURL");
else
	settings.APIKey = GetSetting("ProductionAPIKey");
	settings.BaseVEURL = GetSetting("SandboxBaseVEURL");
end


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
	PrimoVEForm.ImportButton = PrimoVEForm.RibbonPage:CreateButton("Select a single PrimoVE location first", GetClientImage("ImportData32"), "ImportAndUpdateRecord", "Update Record");
	PrimoVEForm.AppendButton = PrimoVEForm.RibbonPage:CreateButton("Append this barcode", GetClientImage("Add32"), "AppendBarcode", "Append a Barcode");
	PrimoVEForm.AppendButton.BarButton.Enabled = false;
	PrimoVEForm.RequestButton = PrimoVEForm.RibbonPage:CreateButton("Request item from holding library", GetClientImage("ImportData32"), "RequestItem", "Request item via API");
	PrimoVEForm.ReportIssueButton = PrimoVEForm.RibbonPage:CreateButton("Report catalog problem", GetClientImage("Alarm32"), "ReportIssue", "Report Catalog Error");
	
	PrimoVEForm.TestButton = PrimoVEForm.RibbonPage:CreateButton("TEST", GetClientImage("ImportData32"), "Test", "Test");
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


-- Atlas Systems encouraged the use of transaction fields ItemNumber and ReferenceNumber.  Unfortunately these are nvarchar(20) and nvarchar(50) respectively.
-- For multivolume lending with delimited barcodes it is necessary to use ItemInfo1 and ItemInfo2 fields as they are nvarchar(255)
-- If a record contains data in ItemNumber or ReferenceNumber fields, transfer them to the new fields and resave the transaction.

oldbarcode = GetFieldValue("Transaction", "ItemNumber");
oldreqid = GetFieldValue("Transaction", "ReferenceNumber");
if (oldbarcode ~= '') then
	SetFieldValue("Transaction","ItemInfo1",oldbarcode);
	SetFieldValue("Transaction","ItemNumber",'');
	ExecuteCommand("Save", {"Transaction"});
end

if (oldreqid ~= '') then
	SetFieldValue("Transaction","ItemInfo2",oldreqid);
	SetFieldValue("Transaction","ReferenceNumber",'');
	ExecuteCommand("Save", {"Transaction"});
end


	
		PrimoVEForm.ImportButton.BarButton.Enabled = false;
		PrimoVEForm.RequestButton.BarButton.Enabled = false;
		
	-- Don't enable Request button if barcodes do not match number of pieces
	if (EnoughBarcodes()) then
	PrimoVEForm.RequestButton.BarButton.Enabled = true;
	PrimoVEForm.RequestButton.BarButton.Caption = "Request item(s) from holding library";
	else
	PrimoVEForm.RequestButton.BarButton.Enabled = false;
	end


end


function AppendBarcode()
local tagElements = PrimoVEForm.Browser.WebBrowser.Document:GetElementsByTagName("prm-location-items");
local appendbarcode = '';

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
		
		local pElements = PrimoVEForm.Browser.WebBrowser.Document:GetElementsByTagName("p");	
		if pElements ~=nil then
			for k=0, pElements.Count - 1 do
				outerHTMLstring = pElements[k].outerHTML
				if outerHTMLstring:match("<p>Barcode: (.-)</p>") then
					appendbarcode = outerHTMLstring:match("<p>Barcode: (.-)</p>")
				end
				
			end
		end
		

	existingbarcodes = GetFieldValue("Transaction", "ItemInfo1");
	updatedbarcodes = existingbarcodes .. "/" .. appendbarcode;
	SetFieldValue("Transaction","ItemInfo1", updatedbarcodes);
	ExecuteCommand("Save", {"Transaction"});
	EnoughBarcodes()

	end
end

function Test()

end

function GetHoldingData(itembarcode)
-- Returns mms_id, holding_id, pid, and location via API using item barcode

local APIAddress = settings.APIEndpoint ..'items?item_barcode=' .. itembarcode .. '&apikey=' .. settings.APIKey
LogDebug('PrimoVE:Attempting to use API endpoint ' .. APIAddress);
LogDebug('PrimoVE:API holding lookup for barcode ' .. itembarcode);

luanet.load_assembly("System");
local APIWebClient = luanet.import_type("System.Net.WebClient");
local streamreader = luanet.import_type("System.Net.IO.StreamReader");
local ThisWebClient = APIWebClient();

local APIResults = ThisWebClient:DownloadString(APIAddress);

LogDebug("PrimoVE:Holdings response was[" .. APIResults .. "]");
	
local mms_id = APIResults:match("<mms_id>(.-)</mms_id");
local holding_id = APIResults:match("<holding_id>(.-)</holding_id>");
local pid = APIResults:match("<pid>(.-)</pid>");
local library = APIResults:match("<library desc=\"(.-)\"");
local location = APIResults:match("<location desc=\"(.-)\"");

local holdinglibrary = library .. " " .. location;

LogDebug('PrimoVE:Found mms_id ' .. mms_id .. ', holding_id ' .. holding_id .. ', pid ' .. pid .. ' for barcode ' .. itembarcode .. " at " .. holdinglibrary);
return mms_id, holding_id, pid, holdinglibrary;
end


function ReportIssue()
-- This feature is not yet active, but should allow ILL practitioners to report catalog issues via SpringShare queues
-- ReportIssueForm.Form = interfaceMngr:CreateForm("ReportIssue", "Script");
-- ReportIssueForm.Browser = ReportIssueForm.Form:CreateBrowser("Report an issue", "Report an Issue", "ReportIssue");
-- local currenturl = tostring(PrimoVEForm.Browser.WebBrowser.Url);
--ReportIssueForm.Form:Show();

end


function RequestItem()
-- Alma Patron Physical Item Request API call
PrimoVEForm.RequestButton.BarButton.Enabled = false;
PrimoVEForm.RequestButton.BarButton.Caption = "Request placed";

local tn = tonumber(GetFieldValue("Transaction", "TransactionNumber"));
local barcodesfielddata = GetFieldValue("Transaction","ItemInfo1");
local barcodearray = {};
local i = 0;

-- LUA empty strings are NOT nil!  Do not attempt request if barcodes are not present
if barcodesfielddata == '' then
	interfaceMngr:ShowMessage("No barcode saved in record - please verify barcode","No barcode");
	ExecuteCommand("SwitchTab", {"Detail"});
	return;
else
	pieces = CountPieces();
	barcodearray = Parse(barcodesfielddata, "/");
	
	if (#barcodearray == pieces) then
		for i = 0,(#barcodearray)-1 do

			-- call function to retrieve mms_id, holding_id, and pid from barcode via API
			mmsid, holdingid, pid, holdinglibrary = GetHoldingData((barcodearray[i+1]));

			LogDebug("PrimoVE:Building Patron Physical Item Request API XML for barcode " .. barcodearray[i+1]);

			local PPIRAPImessage = '';
			PPIRAPImessage = PPIRAPImessage .. '<?xml version="1.0" encoding="UTF-8"?>';
			PPIRAPImessage = PPIRAPImessage .. '<user_request>';
			PPIRAPImessage = PPIRAPImessage .. '<desc>Patron physical item request</desc>';
			PPIRAPImessage = PPIRAPImessage .. '<request_type>HOLD</request_type>';
			PPIRAPImessage = PPIRAPImessage .. '<comment>ILL' .. tn .. '</comment>';
			PPIRAPImessage = PPIRAPImessage .. '<pickup_location_type>LIBRARY</pickup_location_type>';
			PPIRAPImessage = PPIRAPImessage .. '<pickup_location_library>' .. GetSetting("PickupLocationLibrary") .. '</pickup_location_library>';
			PPIRAPImessage = PPIRAPImessage .. '<material_type>BOOK</material_type>'; 
			PPIRAPImessage = PPIRAPImessage .. '</user_request>';
				
			--[[
			This is what a functional API request message looks like:
			<?xml version="1.0" encoding="UTF-8"?>
			<user_request>
			<desc>Patron physical item request</desc>
			<request_type>HOLD</request_type>
			<comment>ILL tn number</comment>
			<pickup_location_type>LIBRARY</pickup_location_type>
			<pickup_location_library>HILL</pickup_location_library>
			<material_type>BOOK</material_type>
			</user_request>
			]]--
				
			
				
			local APIAddress = settings.APIEndpoint .. 'bibs/' .. mmsid .. '/holdings/' .. holdingid ..'/items/' .. pid .. '/requests?apikey=' .. settings.APIKey .. '&user_id=' .. settings.PseudopatronCDS;
			LogDebug('PrimoVE:Attempting to use API Endpoint '.. APIAddress);
			luanet.load_assembly("System");
			local WebClient = luanet.import_type("System.Net.WebClient");
			local PPIRWebClient = WebClient();
			LogDebug("WebClient Created");
			LogDebug("Adding Header");
				
			PPIRWebClient.Headers:Add("Content-Type", "application/xml;charset=UTF-8");
			local PPIRresponseArray = PPIRWebClient:UploadString(APIAddress, PPIRAPImessage);
			LogDebug("Upload response was[" .. PPIRresponseArray .. "]");
			
			-- Add Alma request ID to ILLiad transaction
			local requestID = PPIRresponseArray:match("<request_id>(.-)</request_id");
			LogDebug("PrimoVE:API item request sent to " .. holdinglibrary .. " with request ID " .. requestID .. " for barcode " .. barcodearray[i+1]);
			ExecuteCommand("AddHistory", {tn, "API item request sent to " .. holdinglibrary .. " with request ID " .. requestID .. " for barcode " .. barcodearray[i+1], 'System'});
			existingrequests = GetFieldValue("Transaction","ItemInfo2");
				
			if (existingrequests == '') then
				SetFieldValue("Transaction", "ItemInfo2", requestID);
			else
				updatedrequests = existingrequests .. "/" .. requestID;
				SetFieldValue("Transaction","ItemInfo2", updatedrequests);
			end
				
			--Move to failure queue if API fails
			--Alma currently permits NCIP requests for nonexistent MMS_IDs it isn't possible to do a lot of trapping or validation here
			--APIs provide slightly more flexibility, so it should be possible to parse out XML response LRresponseArray and show details of <Error Message> as a TN History entry if <errorsExist> is TRUE
			--Failed requests should be routed to the failure queue for later intervention
			--ExecuteCommand("Route", {tn, "API Error: LendingRequestItem Failed"});
			
			--Generate a popup here confirming that the request was sent to prevent ILL practitioners from clicking it multiple times
			interfaceMngr:ShowMessage("API item request sent to " .. holdinglibrary .. " with request ID " .. requestID .. " for barcode " .. barcodearray[i+1],"Success");
			ExecuteCommand("SwitchTab", {"Detail"});
			ExecuteCommand("Save", {"Transaction"});
		-- End of Pieces iteration
		end
		
	else interfaceMngr:ShowMessage(pieces - #barcodearray .. " piece(s) missing", "Not enough barcodes");
	ExecuteCommand("SwitchTab", {"Detail"});
	end
		

	-- End of verification that barcodes field is not blank
	end

end

function DefaultURL()
		InitializePageHandler();
		PrimoVEForm.Browser:Navigate(settings.BaseVEURL .. "/discovery/search?");
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
			-- 01122021 button is now labeled aria-label="Expand"
			
			--buttonmatchpattern = "aria%-label=\"Expand/Collapse item\""
			buttonmatchpattern = "aria%-label=\"Expand\""
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
		PrimoVEForm.AppendButton.BarButton.Enabled = true;
		
		if (EnoughBarcodes()) then
			PrimoVEForm.AppendButton.BarButton.Caption = "No more pieces to locate";
			PrimoVEForm.AppendButton.BarButton.Enabled = false;
		else
			PrimoVEForm.AppendButton.BarButton.Caption = "Append this barcode";
			PrimoVEForm.AppendButton.BarButton.Enabled = true;
		end
		
		StopPageWatcher();
	else
		-- We didn't find the SPAN we're looking for on this page, so keep waiting
		StartPageWatcher();
		PrimoVEForm.ImportButton.BarButton.Caption = "Select a single PrimoVE location first";
		PrimoVEForm.ImportButton.BarButton.Enabled = false;
		PrimoVEForm.AppendButton.BarButton.Caption = "Select a single PrimoVE location first";
		PrimoVEForm.AppendButton.BarButton.Enabled = false;
		
	
		
end

return MagicSpanPresent

end

function StartPageWatcher()
    watcherEnabled = true;
    local checkIntervalMilliseconds = 3000; -- 3 seconds
    local maxWatchTimeMilliseconds = 600000; -- 10 minutes
    PrimoVEForm.Browser:StartPageWatcher(checkIntervalMilliseconds, maxWatchTimeMilliseconds);
end --end of StartPageWatcher function

function EnoughBarcodes()
local ParsedBarcodes = {};
local pieces = CountPieces();
local barcodes = GetFieldValue("Transaction","ItemInfo1");

ParsedBarcodes = Parse(barcodes, '/');

if (#ParsedBarcodes == pieces) then
	PrimoVEForm.AppendButton.BarButton.Enabled = false;
	PrimoVEForm.AppendButton.BarButton.Caption = #ParsedBarcodes .. " of " .. pieces .. " barcodes present";
	PrimoVEForm.RequestButton.BarButton.Enabled = true;
	PrimoVEForm.RequestButton.BarButton.Caption = "Request item(s) from holding library";
	return true;
	else if (pieces == 1) then
	PrimoVEForm.AppendButton.BarButton.Caption = "Valid for multipiece requests only";
	PrimoVEForm.AppendButton.BarButton.Enabled = false;
	else
	PrimoVEForm.RequestButton.BarButton.Enabled = false;
	PrimoVEForm.RequestButton.BarButton.Caption = pieces - #ParsedBarcodes .. " barcode(s) missing";
	PrimoVEForm.AppendButton.BarButton.Caption = "Append this barcode";
	return false;
	end
	
end

end -- end of EnoughBarcodes function



-- A simple function that takes delimited string and returns an array of delimited values
function Parse(inputstr, delim)
delim = delim or '/';
local t={};

	for field,s in string.gmatch(inputstr, "([^"..delim.."]*)("..delim.."?)") do 
			table.insert(t,field)
			if s=="" then return t
			end
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
						SetFieldValue("Transaction", "ItemInfo1", barcode);
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
						parsedlocation  = string.gsub(location[j],' %(Request This Item%)','')
						SetFieldValue("Transaction", "Location", library[j].." "..parsedlocation);
					
					end
								
			end
		
		
		else
		PrimoVEForm.ImportButton.BarButton.Enabled = false;
		PrimoVEForm.AppendButton.BarButton.Enabled = false;
		
		end
	PrimoVEForm.ImportButton.BarButton.Enabled = false;
	PrimoVEForm.AppendButton.BarButton.Enabled = false;
	ExecuteCommand("Save", {"Transaction"});
	EnoughBarcodes()
end



--A simple function to get the number of pieces in a transaction for iterative actions
function CountPieces()
local pieces = GetFieldValue("Transaction","Pieces");

	if ((pieces == '' ) or (pieces == nil)) then
		pieces = 1;
		PrimoVEForm.AppendButton.BarButton.Caption = "Valid for multipiece requests only";
		PrimoVEForm.AppendButton.BarButton.Enabled = false;
	else 
		PrimoVEForm.AppendButton.BarButton.Caption = "Add another barcode";
		PrimoVEForm.AppendButton.BarButton.Enabled = true;
	end
return pieces;
end
