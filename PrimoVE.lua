-- About PrimoVE.lua
--
-- version 9.0 records the PrimoVE permalink in the ILL location field to identify when article requests are fulfilled by e-resources that do not have barcodes.
-- version 8.5 includes better support for non-English title searches in PrimoVE by replacing U+FFFD character common in OCLC titles with PrimoVE single-character wildcard '?'
-- additional prompts notify ILL practitioners when items are flagged as non-circulating or in-library use for physical loan requests

-- version 8.0 allows users to toggle Chromium web browser for testing.  Alma will drop support for IE in May 2021.
-- version 7.0 rewrites page-scraping to account for changes to PrimoVE results
-- version 6.0 handles Patron Digitization requests for articles on behalf of a pseudopatron

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

settings.DebugMode = GetSetting("DebugMode");


if (settings.DebugMode == true) then
	LogDebug("PrimoVE: Debug mode is on - Primo search and API requests will act on the sandbox");
	settings.APIKey = GetSetting("SandboxAPIKey");
	settings.BaseVEURL = GetSetting("SandboxBaseVEURL");
else
	LogDebug("PrimoVE: Debug mode is off - Primo search and API requests will act on production");
	settings.APIKey = GetSetting("ProductionAPIKey");
	settings.BaseVEURL = GetSetting("ProductionBaseVEURL");
end

settings.UseChromiumBrowser = GetSetting("UseChromiumBrowser");

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
local ReportIssueForm = {};

PrimoVEForm.Form = nil;
PrimoVEForm.Browser = nil;

ReportIssueForm.Form = nil;
ReportIssueForm.Browser = nil;

local watcherEnabled = false;

PrimoVEForm.RibbonPage = nil;


function Init()

    -- The line below makes this Addon work on all request types.
    if GetFieldValue("Transaction", "RequestType") ~= "" then
		-- Set a global variable if RequestType is defined.
		if GetFieldValue("Transaction", "RequestType") == "Loan" then  
			RequestType = "Loan";
		elseif GetFieldValue("Transaction", "RequestType") == "Article" then
			RequestType =  "Article";
		end
	end
	
	
	interfaceMngr = GetInterfaceManager();
	
	
    -- Create browser
    PrimoVEForm.Form = interfaceMngr:CreateForm("PrimoVE", "Script");
	
	if (settings.UseChromiumBrowser == true) then
		LogDebug("PrimoVE: Using Chromium browser");
		PrimoVEForm.Browser = PrimoVEForm.Form:CreateBrowser("PrimoVE", "PrimoVE", "PrimoVE", "Chromium");
	else
		LogDebug("PrimoVE: Using IE browser");
		PrimoVEForm.Browser = PrimoVEForm.Form:CreateBrowser("PrimoVE", "PrimoVE", "PrimoVE");
		--Suppress Javascript errors.  Not supported for Chromium web brower
		PrimoVEForm.Browser.WebBrowser.ScriptErrorsSuppressed = true;
	end
	
    -- Hide the text labels
    PrimoVEForm.Browser.TextVisible = false;

    -- Since we didn't create a ribbon explicitly before creating our browser, it will have created one using the name we passed the CreateBrowser method. We can retrieve that one and add our buttons to it.
    PrimoVEForm.RibbonPage = PrimoVEForm.Form:GetRibbonPage("PrimoVE");
    -- The GetClientImage("Search32") pulls in the magnifying glass icon. There are other icons that can be used.
	-- Here we are adding a new button to the ribbon
	PrimoVEForm.RibbonPage:CreateButton("Search Title", GetClientImage("Search32"), "SearchTitle", "Search PrimoVE");
	PrimoVEForm.RibbonPage:CreateButton("Search ISxN", GetClientImage("Search32"), "SearchISxN", "Search PrimoVE");
	PrimoVEForm.RibbonPage:CreateButton("Search OCLC#", GetClientImage("Search32"), "SearchOCLC", "Search PrimoVE");
	PrimoVEForm.ImportButton = PrimoVEForm.RibbonPage:CreateButton("Select a single PrimoVE location first", GetClientImage("ImportData32"), "ImportAndUpdateRecord", "Update Record");
	PrimoVEForm.RequestButton = PrimoVEForm.RibbonPage:CreateButton("Request item from holding library", GetClientImage("ImportData32"), "RequestItem", "Request item via API");
	PrimoVEForm.ReportIssueButton = PrimoVEForm.RibbonPage:CreateButton("LibAnswers form", GetClientImage("Alarm32"), "ReportIssue", "Report Catalog Error");
	PrimoVEForm.ReportIssueButton.BarButton.Enabled = true;
	
	if (RequestType == "Article") then
	PrimoVEForm.EResourceButton = PrimoVEForm.RibbonPage:CreateButton("Copy Permalink", GetClientImage("ImportData32"), "FulfillFromEResource", "Fulfill from EResource");
	PrimoVEForm.EResourceButton.BarButton.Enabled = false;
	end
	
	PrimoVEForm.ModeButton = PrimoVEForm.RibbonPage:CreateButton("Operation Mode", GetClientImage(""), "", "Mode");
	PrimoVEForm.ModeButton.BarButton.Enabled = false;
	
	
	if (settings.DebugMode == true) then
		PrimoVEForm.ModeButton.BarButton.Caption = "Sandbox"
	else
		PrimoVEForm.ModeButton.BarButton.Caption = "Production"
	end

	
	
    PrimoVEForm.Form:Show();
    
	
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

	if (GetFieldValue("Transaction", "ISSN") ~= '') then
		SearchISxN();
	elseif (GetFieldValue("Transaction", "ESPNumber") ~='') then
		SearchOCLC();
	else
		SearchTitle();
	end
end

function GetHoldingData(itembarcode)
	-- This function returns mms_id, holding_id, pid, and location via API using item barcode

	local APIAddress = settings.APIEndpoint ..'items?item_barcode=' .. itembarcode .. '&apikey=' .. settings.APIKey
	LogDebug('PrimoVE:Attempting to use API endpoint ' .. APIAddress);
	LogDebug('PrimoVE:API holding lookup for barcode ' .. itembarcode);

	luanet.load_assembly("System");
	local APIWebClient = luanet.import_type("System.Net.WebClient");
	local streamreader = luanet.import_type("System.Net.IO.StreamReader");
	local ThisWebClient = APIWebClient();
	local APIResults = "";

	if pcall(function () APIResults = ThisWebClient:DownloadString(APIAddress); end) then
		LogDebug("PrimoVE:Holdings response was[" .. APIResults .. "]");
		
		local mms_id = APIResults:match("<mms_id>(.-)</mms_id");
		local holding_id = APIResults:match("<holding_id>(.-)</holding_id>");
		local pid = APIResults:match("<pid>(.-)</pid>");
		local library = APIResults:match("<library desc=\"(.-)\"");
		local location = APIResults:match("<location desc=\"(.-)\"");

		local holdinglibrary = library .. " " .. location;

		LogDebug('PrimoVE:Found mms_id ' .. mms_id .. ', holding_id ' .. holding_id .. ', pid ' .. pid .. ' for barcode ' .. itembarcode .. " at " .. holdinglibrary);
		return mms_id, holding_id, pid, holdinglibrary;
	else
		local tn = tonumber(GetFieldValue("Transaction", "TransactionNumber"));
		ExecuteCommand("AddHistory", {tn, "API Failure - holdings lookup failed for barcode " .. itembarcode, 'System'});
		interfaceMngr:ShowMessage("There was a problem performing a holdings lookup over API for barcode " .. itembarcode .. "\nPlease verify the barcode and try again.\nIf issues persist contact ULS IT." ,"Error");
		ExecuteCommand("SwitchTab", {"Detail"});
	end

end


function ReportIssue()
	ReportIssueForm.Form = interfaceMngr:CreateForm("ReportIssue", "Script");

	if (settings.UseChromiumBrowser == true) then
		ReportIssueForm.Browser = ReportIssueForm.Form:CreateBrowser("Report an issue", "Report an Issue", "ReportIssue","Chromium");
	else
		ReportIssueForm.Browser = ReportIssueForm.Form:CreateBrowser("Report an issue", "Report an Issue", "ReportIssue");
	end

	ReportIssueForm.RibbonPage = ReportIssueForm.Form:GetRibbonPage("ReportIssue");
	ReportIssueForm.CloseButton = ReportIssueForm.RibbonPage:CreateButton("Close this form", GetClientImage("Close32"), "CloseReportIssueForm", "Close");

	ReportIssueForm.Form:Show();
	ReportIssueForm.Browser:Navigate('https://pitt.libanswers.com/widget_standalone.php?la_widget_id=1582');

end

function CloseReportIssueForm()
	ReportIssueForm.Form:Close();
end

function RequestItem()
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
		
		elseif (RequestType == "Loan") then
			pieces = CountPieces();
			barcodearray = Parse(barcodesfielddata, "/");
			
			if (#barcodearray > pieces) then
				ExecuteCommand("SwitchTab", {"Detail"});
				interfaceMngr:ShowMessage("# of barcodes exceeds # of pieces.  Please correct and save transaction.","Error");
				return;
			end
			
			if (#barcodearray == pieces) then
				for i = 0,(#barcodearray)-1 do

					-- call function to retrieve mms_id, holding_id, and pid from barcode via API
					local mmsid, holdingid, pid, holdinglibrary = GetHoldingData((barcodearray[i+1]));
					
					-- if the API holdings lookup failed to return all required item data, don't bother trying to perform an API Patron Physical Item Request
					if ((mmsid == nil) or (holdingid == nil) or (pid == nil) or (holdinglibrary == nil)) then
						break;
					end
					
					LogDebug("PrimoVE:Building Patron Physical Item Request API XML for barcode " .. barcodearray[i+1]);

					local PPIRAPImessage = '';
					PPIRAPImessage = PPIRAPImessage .. '<?xml version="1.0" encoding="UTF-8"?>';
					PPIRAPImessage = PPIRAPImessage .. '<user_request>';
					PPIRAPImessage = PPIRAPImessage .. '<desc>Patron physical item request</desc>';
					PPIRAPImessage = PPIRAPImessage .. '<request_type>HOLD</request_type>';
					PPIRAPImessage = PPIRAPImessage .. '<comment>ILL' .. tn .. '</comment>';
					PPIRAPImessage = PPIRAPImessage .. '<pickup_location_type>LIBRARY</pickup_location_type>';
					PPIRAPImessage = PPIRAPImessage .. '<pickup_location_library>' .. GetSetting("PickupLocationLibrary") .. '</pickup_location_library>';
					PPIRAPImessage = PPIRAPImessage .. '</user_request>';
						
					
					--This is what a functional API request message looks like:
					--<?xml version="1.0" encoding="UTF-8"?>
					--<user_request>
					--<desc>Patron physical item request</desc>
					--<request_type>HOLD</request_type>
					--<comment>ILL tn number</comment>
					--<pickup_location_type>LIBRARY</pickup_location_type>
					--<pickup_location_library>HILL</pickup_location_library>
					--<material_type>BOOK</material_type>
					--</user_request>
					
					--material_type removed 02/16/2021 as some requestable materials are not of type BOOK, and while this information is returned by the holdings lookup the API endpoint does not actually require material_type for Patron Physical Item Requests to be submitted
					
					local APIAddress = settings.APIEndpoint .. 'bibs/' .. mmsid .. '/holdings/' .. holdingid ..'/items/' .. pid .. '/requests?apikey=' .. settings.APIKey .. '&user_id=' .. settings.PseudopatronCDS;
					
					LogDebug('PrimoVE:Attempting to use API Endpoint '.. APIAddress);
					local PPIRresponseArray = "";
					luanet.load_assembly("System");
					local WebClient = luanet.import_type("System.Net.WebClient");
					local PPIRWebClient = WebClient();
					LogDebug("WebClient Created");
					LogDebug("Adding Header");
					local PPIResponseArray = "";
										
					PPIRWebClient.Headers:Add("Content-Type", "application/xml;charset=UTF-8");
					
					if pcall(function () PPIRresponseArray = PPIRWebClient:UploadString(APIAddress, PPIRAPImessage) end) then
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
						
									
						--Generate a popup here confirming that the request was sent to prevent ILL practitioners from clicking it multiple times
						interfaceMngr:ShowMessage("API item request sent to " .. holdinglibrary .. " with request ID " .. requestID .. " for barcode " .. barcodearray[i+1],"Success");
						ExecuteCommand("SwitchTab", {"Detail"});
						ExecuteCommand("Save", {"Transaction"});
					else
						ExecuteCommand("AddHistory", {tn, "API Failure - Patron Physical Item Request failed for barcode " .. barcodearray[i+1], 'System'});
						interfaceMngr:ShowMessage("Creation of API Patron Physical Item Request failed for barcode " .. barcodearray[i+1] .."\nPlease verify that the item is requestable in Alma.\nIf issues persist contact ULS IT.","Error");
						ExecuteCommand("SwitchTab", {"Detail"});
						LogDebug("PrimoVE:API Failure - Patron Physical Item Request failed for barcode " .. barcodearray[i+1]);
						
					end
					
			
				-- End of Pieces iteration
				end
				
			else interfaceMngr:ShowMessage(pieces - #barcodearray .. " piece(s) missing", "Not enough barcodes");
			ExecuteCommand("SwitchTab", {"Detail"});
			end

		elseif (RequestType == "Article") then
			
			-- do article stuff
			local pageranges = {};
			local rangesubselect = {};
			local ArticleVolume = GetFieldValue("Transaction","PhotoJournalVolume");
			
			if ((ArticleVolume ~= '') and (tonumber(ArticleVolume) == nil)) then
				interfaceMngr:ShowMessage("ArticleVolume is not a number, and will cause Alma errors.  Please correct and resubmit","Validation Error");
				ExecuteCommand("SwitchTab", {"Detail"});
				return;
			end
			
			local ArticleIssue = GetFieldValue("Transaction","PhotoJournalIssue");
			
			if ((ArticleIssue ~= '') and (tonumber(ArticleIssue) == nil)) then
				interfaceMngr:ShowMessage("ArticleIssue is not a number, and will cause Alma errors.  Please correct and resubmit","Validation Error");
				ExecuteCommand("SwitchTab", {"Detail"});
				return;
			end
			
			local ArticleMonth = GetFieldValue("Transaction","PhotoJournalMonth");
			local ArticleYear = GetFieldValue("Transaction","PhotoJournalYear");
			local ArticlePages = GetFieldValue("Transaction","PhotoJournalInclusivePages");
			local ArticleAuthor = GetFieldValue("Transaction","PhotoArticleAuthor");
			local ArticleTitle = GetFieldValue("Transaction","PhotoArticleTitle");
			
			-- NOTE: Alma digitization requests currently permit only two page ranges!
			pageranges = Parse(ArticlePages, ",");
			if (#pageranges) > 2 then
				interfaceMngr:ShowMessage("This request contains " .. #pageranges .. " delimited page ranges.  Alma supports only two.  This request must be created manually.","Error");
				ExecuteCommand("SwitchTab", {"Detail"});
				return;
			end
		
			-- call function to retrieve mms_id, holding_id, and pid from barcode via API
				local mmsid, holdingid, pid, holdinglibrary = GetHoldingData(barcodesfielddata);

				LogDebug("PrimoVE:Building Patron Digitization Request API XML for barcode " .. barcodesfielddata);
				

				-- a correctly formatted API Patron Digitization Request looks like this
				--	<user_request>
				--	  <request_type>DIGITIZATION</request_type>
				--	  <request_sub_type desc="Patron digitization request">PHYSICAL_TO_DIGITIZATION</request_sub_type>
				--	  <comment>ILL 01262021 Volume 64 Issue 4 2020 pp 490-495</comment>
				--	  <target_destination>Default</target_destination>
				--	  <material_type>BOOK</material_type>
				--	  <partial_digitization>true</partial_digitization>
				--	  <chapter_or_article_author></chapter_or_article_author>
				--	  <chapter_or_article_title></chapter_or_article_title>
				--	  <date_of_publication></date_of_publication>
				--	  <volume></volume>
				--	  <issue></issue>
				--		 <required_pages>
				--		<required_pages_range>
				--		  <from_page>1</from_page>
				--		  <to_page>6</to_page>
				--		</required_pages_range>
				--		 <required_pages_range>
				--		  <from_page>10</from_page>
				--		  <to_page>14</to_page>
				--		</required_pages_range>
				--	  </required_pages>
				--	  <copyrights_declaration_signed_by_patron>true</copyrights_declaration_signed_by_patron>
				--	</user_request>
				
				local PDigiAPImessage = '';
				PDigiAPImessage = PDigiAPImessage .. '<user_request>';
				PDigiAPImessage = PDigiAPImessage .. '<request_type>DIGITIZATION</request_type>';
				PDigiAPImessage = PDigiAPImessage .. '<request_sub_type desc="Patron digitization request">PHYSICAL_TO_DIGITIZATION</request_sub_type>';
				
				local commentstring = '';
				commentstring = 'ILL' .. tn;
				
				if ArticleVolume ~= '' then
					commentstring = commentstring .. ' Vol. ' .. ArticleVolume;
					PDigiAPImessage = PDigiAPImessage .. '<volume>' .. ArticleVolume .. '</volume>';
				end
				
				if ArticleIssue ~= '' then
					commentstring = commentstring .. ' Issue ' .. ArticleIssue;
					PDigiAPImessage = PDigiAPImessage .. '<issue>' .. ArticleIssue .. '</issue>';
				end
				
				commentstring = commentstring .. ' Pages ' .. ArticlePages;
				
				PDigiAPImessage = PDigiAPImessage .. '<comment>' .. commentstring .. '</comment>';
				
				PDigiAPImessage = PDigiAPImessage .. '<target_destination>Default</target_destination>';
				PDigiAPImessage = PDigiAPImessage .. '<material_type>BOOK</material_type>';
				PDigiAPImessage = PDigiAPImessage .. '<partial_digitization>true</partial_digitization>';
				PDigiAPImessage = PDigiAPImessage .. '<chapter_or_article_author>' .. ArticleAuthor .. '</chapter_or_article_author>';
				PDigiAPImessage = PDigiAPImessage .. '<chapter_or_article_title>' .. ArticleTitle .. '</chapter_or_article_title>';
				
				local publicationdate = '';
				if (ArticleMonth ~= '') then
					publicationdate = ArticleMonth .. " " .. ArticleYear;
				else
					publicationdate = ArticleYear;
				end
				
				PDigiAPImessage = PDigiAPImessage .. '<date_of_publication>' .. publicationdate ..'</date_of_publication>';
				
				PDigiAPImessage = PDigiAPImessage .. '<required_pages>'
				
				for i = 0,(#pageranges)-1 do
					-- do stuff for each page range (parse using hyphen)
					rangesubselect = Parse(pageranges[i+1], "-");
					
					PDigiAPImessage = PDigiAPImessage .. '<required_pages_range>';
					PDigiAPImessage = PDigiAPImessage .. '<from_page>' .. rangesubselect[1] .. '</from_page>';
					
					-- trap in case these are single pages and not a range
					if (rangesubselect[2] == '') then
						rangesubselect[2] = rangesubselect[1];
					elseif (rangesubselect[1] > rangesubselect[2]) then
						interfaceMngr:ShowMessage("Upper bound of page range is less than lower bound; this will cause an Alma error.  Please correct article Pages field values","Page range error");
						ExecuteCommand("SwitchTab", {"Detail"});
						return;
					end
					
					
					PDigiAPImessage = PDigiAPImessage .. '<to_page>' .. rangesubselect[2] .. '</to_page>';
					PDigiAPImessage = PDigiAPImessage .. '</required_pages_range>';
				end
				
				PDigiAPImessage = PDigiAPImessage .. '</required_pages>';
				PDigiAPImessage = PDigiAPImessage .. '<copyrights_declaration_signed_by_patron>true</copyrights_declaration_signed_by_patron>';
				PDigiAPImessage = PDigiAPImessage .. '</user_request>';
				
				local APIAddress = settings.APIEndpoint .. 'bibs/' .. mmsid .. '/holdings/' .. holdingid ..'/items/' .. pid .. '/requests?apikey=' .. settings.APIKey .. '&user_id=' .. settings.PseudopatronCDS;
				LogDebug('PrimoVE:Attempting to use API Endpoint '.. APIAddress);
				luanet.load_assembly("System");
				local WebClient = luanet.import_type("System.Net.WebClient");
				local PDigiWebClient = WebClient();
				LogDebug("WebClient Created");
				LogDebug("Adding Header");
						
				PDigiWebClient.Headers:Add("Content-Type", "application/xml;charset=UTF-8");
				local PDigiResponseArray = "";
				
				if pcall(function () PDigiResponseArray = PDigiWebClient:UploadString(APIAddress, PDigiAPImessage); end) then

					LogDebug("Upload response was[" .. PDigiResponseArray .. "]");
					
					-- Add Alma digitization request ID to ILLiad transaction
					local requestID = PDigiResponseArray:match("<request_id>(.-)</request_id");
					LogDebug("PrimoVE:API digitization request sent to " .. holdinglibrary .. " with request ID " .. requestID .. " for barcode " .. barcodesfielddata);
					ExecuteCommand("AddHistory", {tn, "API digitization request sent to " .. holdinglibrary .. " with request ID " .. requestID .. " for barcode " .. barcodesfielddata, 'System'});
					SetFieldValue("Transaction","ItemInfo2", requestID);
				
					--Generate a popup here confirming that the digitization request was sent to prevent ILL practitioners from clicking it multiple times
					interfaceMngr:ShowMessage("API digitization request sent to " .. holdinglibrary .. " with request ID " .. requestID .. " for barcode " .. barcodesfielddata,"Success");
					ExecuteCommand("SwitchTab", {"Detail"});
					ExecuteCommand("Save", {"Transaction"});

				else
					ExecuteCommand("AddHistory", {tn, "API Failure - digitization request failed for barcode " .. barcodesfielddata, 'System'});
					interfaceMngr:ShowMessage("There was a problem creating a digitization request over API for barcode " .. barcodesfielddata .. "\nPlease verify the barcode and try again.\nIf issues persist contact ULS IT." ,"Error");
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
		PrimoVEForm.Browser:Navigate(settings.BaseVEURL .. "/discovery/search?query=any,contains,*" .. GetFieldValue("Transaction", "ESPNumber") .. "&tab=LibraryCatalog&search_scope=MyInstitution&sortby=rank&vid=" .. settings.DatabaseName .. "&lang=en_US&offset=0");
	else
		interfaceMngr:ShowMessage("OCLC# is not available from request form", "Insufficient Information");
	end
end


-- This function performs a standard search for LoanTitle for Loan requests and PhotoJournalTitle for Article requests.
function SearchTitle()
	InitializePageHandler();
	local title = '';
		
    if (RequestType == "Loan" )then  
		title = GetFieldValue("Transaction", "LoanTitle");
	elseif (RequestType == "Article") then 
		title = GetFieldValue("Transaction", "PhotoJournalTitle");
	end
	
	-- OCLC requests do not handle non-Latin characters well.  Some ISO/IEC 8859-1 characters are represented as Unicode U+FFFD, which PrimoVE doesn't handle well in the search box
	-- To remove the need for ILL practitioners to remove each instance of U+FFFD from non-English titles, replace each instance with PrimoVE single character wildcard "?"
	
	title = string.gsub(title,'�','?');
	if (title ~= '') then
		PrimoVEForm.Browser:Navigate(settings.BaseVEURL .. "/discovery/search?query=any,contains," .. title .. "&tab=LibraryCatalog&search_scope=MyInstitution&sortby=rank&vid=" .. settings.DatabaseName .. "&lang=en_US&offset=0");
	else
		interfaceMngr:ShowMessage("The title is not available from request form", "Insufficient Information");
	end
end

function CheckPageIE()
	-- first check to verify that a single record has been selected, but don't bother doing a deep dive unless the URL looks like a discovery result
	local IsRecordExpanded = false;
	local SingleLocationSelected = false;
	EnoughBarcodes();

	local currenturl = tostring(PrimoVEForm.Browser.WebBrowser.Url);

	if (currenturl and currenturl:find("/discovery/fulldisplay")) then
		LogDebug("PrimoVE:IE current URL is a fulldisplay result.  Looking for 'Back to Locations' span");
		-- iterate through spans looking for "Back to Locations"
		local spanElements = PrimoVEForm.Browser.WebBrowser.Document:GetElementsByTagName("span");
		
		for i=0, spanElements.Count - 1 do
		
			spanElement = PrimoVEForm.Browser:GetElementByCollectionIndex(spanElements, i);
			if spanElement.InnerText == "Back to locations" then
				SingleLocationSelected = true;
				break;
			else 
				SingleLocationSelected = false;
			end
		
		end

	end

	if (SingleLocationSelected) then
			-- We found a SPAN that indicates a single record was selected.   Enable button to permit barcodes etc to be scraped from page
		local buttonsfound = 0;
		local buttonarray = PrimoVEForm.Browser.WebBrowser.Document:GetElementsByTagName("button");
			
			if (IsRecordExpanded == false) then
				
				--ESCAPE QUOTES WITH \
				--ESCAPE ( ) . % + - * ? [ ^ $ with %
				-- As of 01122021 button previously labeled aria-label="Expand/Collapse item" is now labeled aria-label="Expand" and aria-label="Collapse" depending on button state
				
				local buttonmatchpattern = "aria%-label=\"Collapse\""
				
				for j=0, buttonarray.Count -1 do
				
					
					local button = PrimoVEForm.Browser:GetElementByCollectionIndex(buttonarray, j);
									
					if (button.outerHTML:find(buttonmatchpattern)) ~= nil then
						buttonsfound = buttonsfound + 1;
					end
				end
				
				
			end
			
			if (buttonsfound == 1) then
				IsRecordExpanded = true;
				PrimoVEForm.ImportButton.BarButton.Enabled = true;
				EnoughBarcodes();
			else
				PrimoVEForm.ImportButton.BarButton.Enabled = false;
				PrimoVEForm.ImportButton.BarButton.Caption = "Select a single item";
			end;
							
			
		else
			-- We didn't find the SPAN we're looking for on this page, so keep waiting
			StartPageWatcher();
			
			if (CountPieces() == 0) then
				PrimoVEForm.ImportButton.BarButton.Caption = "# pieces missing";
			else
				PrimoVEForm.ImportButton.BarButton.Caption = "Select a single PrimoVE location first";
			end
			PrimoVEForm.ImportButton.BarButton.Enabled = false;
			
		
	end

	return IsRecordExpanded;

end

function FulfillFromEResource()

	local JSGetViewOnline = [[
	(function() {
	var headings = document.querySelectorAll('h4.section-title.md-title.light-text');
	var i;
	for (i=0; i<headings.length; i++){
	if(headings[i].innerHTML == "View Online"){
	return true;}
	}
	return false;
	})
	]];
		


		local ViewableOnline = PrimoVEForm.Browser:EvaluateScript(JSGetViewOnline,'');
		if (ViewableOnline.Success) then 
			if (ViewableOnline.Result == true) then
						
			local JSClickPermalink = [[
				(function() {
							
				var permalinkbutton = document.querySelectorAll("button[aria-label='Permalink']");
				return permalinkbutton[0].click();
				
				})
				]];
			
			local JSGetPermalink = [[
				(function() {
								
				var permalink = document.querySelectorAll("span[id^='permalinkalma'");
				
				var permalinkresult = permalink[1].innerHTML;
				
				return permalinkresult;
				
				
				})
				]];
			
			local JSCopyToClipboard = [[
				(function() {
							
				var permalinkbutton = document.querySelectorAll("button[aria-label='Copy the permalink to clipboard']");
				return permalinkbutton[1].click();
				
				})
				]];
				
				
			local permalinkbutton = PrimoVEForm.Browser:EvaluateScript(JSClickPermalink,'');
			
			if (permalinkbutton.Success) then
				LogDebug("PrimoVE: Clicked the permalink button");
				-- This is an ugly hack, but we need to give the PrimoVE result page time to load once the Permalink button has been clicked
				-- Javascript runs asynchronously, and setTimeout approaches within JS were not working consistently
				sleep(1);
				
				local permalink = PrimoVEForm.Browser:EvaluateScript(JSGetPermalink,'');
				if (permalink.Success) then
					PrimoVEForm.Browser:EvaluateScript(JSCopyToClipboard,'');
					SetFieldValue("Transaction", "Location", "Fulfilled from EResource: " .. permalink.Result);
					ExecuteCommand("SwitchTab", {"Detail"});
					ExecuteCommand("Save", {"Transaction"});
				else
					LogDebug("PrimoVE: Javascript error obtaining permalink " .. permalink.Message);
				end
			else
				LogDebug("PrimoVE: Javascript error clicking permalink button " .. permalinkbutton.Message);
			end
						
		
		else
			LogDebug("PrimoVE: Javascript error: " .. ViewableOnline.Message);
		end

	end
	
		
end

function sleep(s)
  local ntime = os.time() + s
  repeat until os.time() > ntime
end

function CheckPageChromium()
	-- Before prompting the ILL practitioner to import barcode, location, library, and call number, we need to ensure that the following criteria are met
	-- 1) The user has clicked a record from the PrimoVE search page
	-- 2) The user has selected a location where that item is held
	-- 3) The user has selected a single item record
	-- The ILLiad Chromium Browser doesn't have native support for GetElementsByTagName or GetElementByCollectionIndex methods, so as a workaround the browser
	-- calls Javascript functions that perform these tasks.
	-- The ILLiad EvaluateScript() browser method returns:
	-- .Success - a boolean indicating whether the script execution succeeded
	-- .Result - whatever the script returns (if anything)
	-- .Message - if an error occurs, the error should be passed here

	-- first check to verify that the URL looks like a discovery result
	local IsRecordExpanded = false;
	local SingleLocationSelected = false;
	--EnoughBarcodes();

	local currenturl = tostring(PrimoVEForm.Browser.WebBrowser.Address);

	if (currenturl and currenturl:find("/discovery/fulldisplay")) then
		-- for article requests, determine whether request can be fulfilled from EResources (Internet Archive, etc) links in PrimoVE
		if (RequestType == "Article") then
			PrimoVEForm.EResourceButton.BarButton.Enabled = true;
		end
		
		-- We're now looking at a PrimoVE results page.  Next iterate through spans looking for "Back to Locations"
		local JSGetLocationSpan = [[
			(function() {
		var spans = document.querySelectorAll("span");
		var i;
		for (i=0; i<spans.length; i++){
		if(spans[i].innerHTML == "Back to locations"){
		return true;}
		}
		return false;
		})
		]];

		if ((PrimoVEForm.Browser.WebBrowser.IsLoading == false)) then
			local spanElements = PrimoVEForm.Browser:EvaluateScript(JSGetLocationSpan,'');
			if (spanElements.Success) then 
				if (spanElements.Result == true) then
					SingleLocationSelected = true;
				end
			else
				LogDebug("PrimoVE: Javascript error: " .. spanElements.Message);
			end
		end

		local JSGetCollapseButton = [[
			(function() {
		var buttons = document.querySelectorAll("button[aria-Label='Collapse']");
		return buttons.length;
		})
		]];

			if (SingleLocationSelected) then
				-- We're looking at a single location, so look for PrimoVE "Collapse" buttons
				local buttons = PrimoVEForm.Browser:EvaluateScript(JSGetCollapseButton,'');
				if (buttons.Success) then
					buttonsfound = buttons.Result
				else
					LogDebug("PrimoVE: Javascript error: " .. buttons.Message);
				end
						
				if (buttonsfound == 1) then
					-- Only one item is selected, so proceed
					IsRecordExpanded = true;
					PrimoVEForm.ImportButton.BarButton.Enabled = true;
					EnoughBarcodes();
				else
					-- Either zero items are expanded, or more than one.  Prompt the user to refine their selection.
					PrimoVEForm.ImportButton.BarButton.Enabled = false;
					PrimoVEForm.ImportButton.BarButton.Caption = "Select a single item";
				end;
								
			else
				-- Keep waiting until a single location is selected
				StartPageWatcher();
				
				if (CountPieces() == 0) then
					PrimoVEForm.ImportButton.BarButton.Caption = "# pieces missing";
				else
					PrimoVEForm.ImportButton.BarButton.Caption = "Select a single PrimoVE location first";
				end
				PrimoVEForm.ImportButton.BarButton.Enabled = false;
				
			end	




		end -- end of search for fulldisplay record

	return IsRecordExpanded;

end

function StartPageWatcher()
    watcherEnabled = true;
    local checkIntervalMilliseconds = 2000; -- 2 seconds
    local maxWatchTimeMilliseconds = 1200000; -- 20 minutes
    PrimoVEForm.Browser:StartPageWatcher(checkIntervalMilliseconds, maxWatchTimeMilliseconds);
end --end of StartPageWatcher function



function EnoughBarcodes()
	local ParsedBarcodes = {};
	local pieces = CountPieces();

	local barcodes = GetFieldValue("Transaction","ItemInfo1");

	ParsedBarcodes = Parse(barcodes, '/');

	if (pieces == 0) then
		PrimoVEForm.ImportButton.BarButton.Enabled = false;
		PrimoVEForm.ImportButton.BarButton.Caption = "# pieces missing";
		PrimoVEForm.RequestButton.BarButton.Enabled = false;
		PrimoVEForm.RequestButton.BarButton.Caption = "# pieces missing";
		return false;
	elseif (#ParsedBarcodes == pieces) then
		PrimoVEForm.ImportButton.BarButton.Enabled = false;
		PrimoVEForm.ImportButton.BarButton.Caption = #ParsedBarcodes .. " of " .. pieces .. " barcodes present";
		PrimoVEForm.RequestButton.BarButton.Enabled = true;
		PrimoVEForm.RequestButton.BarButton.Caption = "Request item(s) from holding library";
		StopPageWatcher();
		return true;
	elseif ((pieces == 1) or (#ParsedBarcodes == 0)) then
		PrimoVEForm.ImportButton.BarButton.Caption = "Import call number, location, and barcode";
		return false;
	else
		PrimoVEForm.RequestButton.BarButton.Enabled = false;
		PrimoVEForm.RequestButton.BarButton.Caption = pieces - #ParsedBarcodes .. " barcode(s) missing";
		PrimoVEForm.ImportButton.BarButton.Caption = "Append this barcode";
		return false;
	end

end -- end of EnoughBarcodes function



-- A simple function that takes delimited string and returns an array of delimited values
function Parse(inputstr, delim)
	if (inputstr == "") then return "";
	else
	delim = delim or '/';
	local result = {};
	local match = '';

	for match in (inputstr..delim):gmatch("(.-)"..delim) do
		table.insert(result,match);
	end
		return result;
	end

end
	


function StopPageWatcher()
    if watcherEnabled then
        PrimoVEForm.Browser:StopPageWatcher();
    end

    watcherEnabled = false;
end

function InitializePageHandler()
	if (settings.UseChromiumBrowser == true) then
		PrimoVEForm.Browser:RegisterPageHandler("custom", "CheckPageChromium", "PageHandler", false);
	elseif (settings.UseChromiumBrowser == false) then
		PrimoVEForm.Browser:RegisterPageHandler("custom", "CheckPageIE", "PageHandler", false);
	end

end


function PageHandler()
	InitializePageHandler();
end

function ImportAndUpdateRecord()
	if (settings.UseChromiumBrowser == true) then
		ImportAndUpdateRecordChromium();
	elseif (settings.UseChromiumBrowser == false) then
		ImportAndUpdateRecordIE();
	end
end

function ImportAndUpdateRecordChromium()
	local existingbarcodes = GetFieldValue("Transaction", "ItemInfo1");

	local JSGetItemInfo = [[
	(function(regexmatchpattern) {
	var regex = new RegExp(regexmatchpattern);
	var iteminfo = document.querySelectorAll("prm-location-items")[0].innerHTML;
	var iteminfo = iteminfo.match(regex);
	return iteminfo[1];
	})
	]];

	local barcoderegexmatchpattern = [[<p>Barcode: (.*?)<\/p>]];
	local barcode = PrimoVEForm.Browser:EvaluateScript(JSGetItemInfo,barcoderegexmatchpattern);
	if (barcode.Success) then
		barcode = tostring(barcode.Result);
		LogDebug("PrimoVE: Javascript found barcode " .. barcode);
	else
		LogDebug("PrimoVE: Javascript error: " .. barcode.Message);
	end

	local availabilityregexmatchpattern = [[<span class=\\"availability-status available\\" translate=\\"fulldisplay\\.availabilty\\.available\\">(.*?)<]];
	local availability = PrimoVEForm.Browser:EvaluateScript(JSGetItemInfo,availabilityregexmatchpattern);
	if (availability.Success) then
		availability = tostring(availability.Result);
		LogDebug("PrimoVE: Javascript found availability " .. availability);
	else
		LogDebug("PrimoVE: Javascript error: " .. availability.Message);
	end

	local libraryregexmatchpattern = [[\\$ctrl\\.getLibraryName\\(\\$ctrl\\.currLoc\\.location\\)\\" class=\\"md-title ng-binding zero-margin\\">(.*?)<\/h4>]];
	local library = PrimoVEForm.Browser:EvaluateScript(JSGetItemInfo,libraryregexmatchpattern);
	if (library.Success) then
		library = tostring(library.Result);
		LogDebug("PrimoVE: Javascript found library " .. library);
	else
		LogDebug("PrimoVE: Javascript error: " .. library.Message);
	end

	local locationregexmatchpattern = [[<span ng-if=\\"\\$ctrl\\.currLoc\\.location &amp;&amp; \\$ctrl\\.currLoc\\.location\\.subLocation &amp;&amp; \\$ctrl\\.getSubLibraryName\\(\\$ctrl\\.currLoc\\.location\\)\\" ng-bind-html=\\"\\$ctrl\\.currLoc\\.location\\.collectionTranslation\\">(.*?)<\/span>]];
	local location = PrimoVEForm.Browser:EvaluateScript(JSGetItemInfo,locationregexmatchpattern);
	if (location.Success) then
		location = tostring(location.Result);
		LogDebug("PrimoVE: Javascript found location " .. location);
	else
		LogDebug("PrimoVE: Javascript error: " .. location.Message);
	end		

	local callnumberregexmatchpattern = [[<span ng-if=\\"\\$ctrl\\.currLoc\\.location\\.callNumber\\" dir=\\"auto\\">(.*?)<\/span>]];
	local callnumber = PrimoVEForm.Browser:EvaluateScript(JSGetItemInfo,callnumberregexmatchpattern);
	if (callnumber.Success) then
		callnumber = tostring(callnumber.Result);
		LogDebug("PrimoVE: Javascript found call number " .. callnumber);
	else
		LogDebug("PrimoVE: Javascript error: " .. callnumber.Message);
		-- some ULS items may not have call numbers.
		callnumber = '';
	end		

	if (string.find(existingbarcodes,barcode) ~= nil) then
		interfaceMngr:ShowMessage("Barcode " .. barcode .. " was already added to this transaction!","Duplicate barcode");
		return;
	end


	if (availability ~= "Available") then
		interfaceMngr:ShowMessage("Item with barcode " .. barcode .. " is shown as not available.","Warning - Item availability");
	end

	-- The ULS has added "(In-library use only)" and "(non-circulating)" to the display names of sublibraries
	-- While item policies should prevent Patron Physical Item Requests to be submitted for these items, it is better
	-- to warn ILL practitioners and prevent them from doing so in the first place.
	-- This applies only to physical item loans, as rare, fragile, or noncirculating materials are still digitization candidates

	if (RequestType == "Loan") then
		if (string.find(location, "%(In%-library use only%)")) then
			interfaceMngr:ShowMessage("Item with barcode " .. barcode .. " is flagged as in-library use only.","Warning - In-Library Use Only");
		end
		if (string.find(location, "%(non%-circulating%)")) then
			interfaceMngr:ShowMessage("Item with barcode " .. barcode .. " is flagged as non-circulating.","Warning - Non-Circulating");
		end
	end

	if (existingbarcodes == "" or existingbarcodes == nil) then						
		SetFieldValue("Transaction", "ItemInfo1", barcode);
					
		--If no barcode exists in the transaction, then we obtain the callnumber, library, and location for the first barcode selected.  There is no need to append all locations for each barcode, as ILL staff use these only for referencee
					
		if (callnumber ~= nil) then 
			SetFieldValue("Transaction", "CallNumber", callnumber);
		end
							
		if ((library ~= nil) and (location ~= nil)) then
			-- the "&amp;" obtained from PrimoVE innerHTML should be replaced
			local parsedlibrary = string.gsub(library,'&amp;','&');
			local parsedlocation = string.gsub(location,'&amp;','&');
			
			-- remove ULS "(Request This Item)" that appears in sublocations
			parsedlocation = string.gsub(parsedlocation,' %(Request This Item%)','');
						
			SetFieldValue("Transaction", "Location", parsedlibrary.." "..parsedlocation);
		end
					
	else
		local appendedbarcodes = existingbarcodes .. "/" .. barcode;
		SetFieldValue("Transaction","ItemInfo1", appendedbarcodes);
	end
										
	PrimoVEForm.ImportButton.BarButton.Enabled = false;

	ExecuteCommand("Save", {"Transaction"});
	EnoughBarcodes();
end


function ImportAndUpdateRecordIE()
	--Determine whether we need to update call number, library, and location, or just append another delimited barcode
	local existingbarcodes = GetFieldValue("Transaction", "ItemInfo1");
	local tagElements = PrimoVEForm.Browser.WebBrowser.Document:GetElementsByTagName("prm-location-items");

	local status = {} ;
	local library = {} ;
	local location = {} ;
	local callnumber = {} ;
	local barcode = {};

	--MATCH STRINGS
	--Item status
	--<span class="availability-status available" translate="fulldisplay.availabilty.available">
	--Item location
	--<h4 class="md-title ng-binding zero-margin" ng-if="$ctrl.currLoc.location &amp;&amp; $ctrl.getLibraryName($ctrl.currLoc.location)">
	--Library
	--<span ng-if="$ctrl.currLoc.location &amp;&amp; $ctrl.currLoc.location.subLocation &amp;&amp; $ctrl.getSubLibraryName($ctrl.currLoc.location)" ng-bind-html="$ctrl.currLoc.location.collectionTranslation">
	--Call number
	--<span dir="auto" ng-if="$ctrl.currLoc.location.callNumber">
	--ESCAPE QUOTES WITH \
	--ESCAPE ( ) . % + - * ? [ ^ $ with %
	--[SIC] fulldisplay.availbilty.available is not spelled correctly because PrimoVE spells the class this way
	--<span class=\"availability%-status available\" translate=\"fulldisplay%.availabilty%.available\">
	--<h4 class=\"md%-title ng%-binding zero%-margin\" ng%-if=\"%$ctrl%.currLoc%.location &amp;&amp; %$ctrl%.getLibraryName%(%$ctrl%.currLoc%.location%)\">
	--<span ng%-if=\"%$ctrl%.currLoc%.location &amp;&amp; %$ctrl%.currLoc%.location%.subLocation &amp;&amp; %$ctrl%.getSubLibraryName%(%$ctrl%.currLoc%.location%)\" ng%-bind%-html=\"%$ctrl%.currLoc%.location%.collectionTranslation\">
	--<span dir=\"auto\" ng%-if=\"%$ctrl%.currLoc%.location%.callNumber\">

		if tagElements ~= nil then
			for j=0, tagElements.Count - 1 do
				divElement = PrimoVEForm.Browser:GetElementByCollectionIndex(tagElements, j);
				innerhtmlstring = divElement.innerHTML;
			
				barcode[j] = innerhtmlstring:match("<p>Barcode: (.-)</p>")
							
				--eliminate the risk of impatient users clicking the button to add/append the same barcode multiple times
				if (string.find(existingbarcodes,barcode[j]) ~= nil) then
					interfaceMngr:ShowMessage("Barcode " .. barcode[j] .. " was already added to this transaction!","Duplicate barcode");
					return;
				end
							
				if (existingbarcodes == "" or existingbarcodes == nil) then						
					SetFieldValue("Transaction", "ItemInfo1", barcode[j]);
					
					--If no barcode exists in the transaction, then we obtain the callnumber, library, and location for the first barcode selected.  There is no need to append all locations for each barcode, as ILL staff use these only for referencee
					
				
					-- Item "Available" status could be used in the future to prevent placing requests for items that are on loan or missing
					status[j] = innerhtmlstring:match("<span class=\"availability%-status available\" translate=\"fulldisplay%.availabilty%.available\">(.-)<");
							
					library[j] = innerhtmlstring:match("<h4 class=\"md%-title ng%-binding zero%-margin\" ng%-if=\"%$ctrl%.currLoc%.location &amp;&amp; %$ctrl%.getLibraryName%(%$ctrl%.currLoc%.location%)\">(.-)<");
					location[j] = innerhtmlstring:match("<span ng%-if=\"%$ctrl%.currLoc%.location &amp;&amp; %$ctrl%.currLoc%.location%.subLocation &amp;&amp; %$ctrl%.getSubLibraryName%(%$ctrl%.currLoc%.location%)\" ng%-bind%-html=\"%$ctrl%.currLoc%.location%.collectionTranslation\">(.-)<");
					callnumber[j]= innerhtmlstring:match("<span dir=\"auto\" ng%-if=\"%$ctrl%.currLoc%.location%.callNumber\">(.-)<");
							
					if (callnumber[j] ~= nil) then 
						SetFieldValue("Transaction", "CallNumber", callnumber[j]);
					end
							
							
					if ((library[j] ~= nil) and (location[j] ~= nil)) then
						parsedlocation  = string.gsub(location[j],' %(Request This Item%)','')
						SetFieldValue("Transaction", "Location", library[j].." "..parsedlocation);
					end
					
					
				else
					local appendedbarcodes = existingbarcodes .. "/" .. barcode[j];
					SetFieldValue("Transaction","ItemInfo1", appendedbarcodes);
				end
							
					
			end
				
			
		else
			PrimoVEForm.ImportButton.BarButton.Enabled = false;
			
		end
		

	ExecuteCommand("Save", {"Transaction"});
	EnoughBarcodes();
end



--A simple function to get the number of pieces in a transaction for iterative actions
function CountPieces()
	local pieces = GetFieldValue("Transaction","Pieces");
	if ((pieces == '' ) or (pieces == nil)) then
		pieces = 0;
		end
	return pieces;
end
