-- About PrimoVE.lua
--
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
settings.BaseVEURL = GetSetting("BaseVEURL")
settings.DatabaseName = GetSetting("DatabaseName");

local interfaceMngr = nil;
local PrimoVEForm = {};
PrimoVEForm.Form = nil;
PrimoVEForm.Browser = nil;
PrimoVEForm.RibbonPage = nil;

function Init()
    -- The line below makes this Addon work on all request types.
    if GetFieldValue("Transaction", "RequestType") ~= "" then
    interfaceMngr = GetInterfaceManager();

    -- Create browser
    PrimoVEForm.Form = interfaceMngr:CreateForm("PrimoVE", "Script");
    PrimoVEForm.Browser = PrimoVEForm.Form:CreateBrowser("PrimoVE", "PrimoVE", "PrimoVE");

    -- Hide the text label
    PrimoVEForm.Browser.TextVisible = false;

    --Suppress Javascript errors
    PrimoVEForm.Browser.WebBrowser.ScriptErrorsSuppressed = true;

    -- Since we didn't create a ribbon explicitly before creating our browser, it will have created one using the name we passed the CreateBrowser method. We can retrieve that one and add our buttons to it.
    PrimoVEForm.RibbonPage = PrimoVEForm.Form:GetRibbonPage("PrimoVE");
    -- The GetClientImage("Search32") pulls in the magnifying glass icon. There are other icons that can be used.
	-- Here we are adding a new button to the ribbon
	PrimoVEForm.RibbonPage:CreateButton("Search ISxN", GetClientImage("Search32"), "SearchISxN", "PrimoVE");
	PrimoVEForm.RibbonPage:CreateButton("Search OCLC#", GetClientImage("Search32"), "SearchOCLC", "PrimoVE");
	PrimoVEForm.RibbonPage:CreateButton("Search Title", GetClientImage("Search32"), "SearchTitle", "PrimoVE");
	PrimoVEForm.RibbonPage:CreateButton("Import Call Number/Location", GetClientImage("Search32"), "ImportCallNumber", "PrimoVE");

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
end

function DefaultURL()
		PrimoVEForm.Browser:Navigate(settings.PrimoVEURL);
end

-- This function searches for ISxN for both Loan and Article requests.
function SearchISxN()
    if GetFieldValue("Transaction", "ISSN") ~= "" then
		PrimoVEForm.Browser:Navigate(settings.BaseVEURL .. "/discovery/search?query=any,contains," .. GetFieldValue("Transaction", "ISSN") .. "&tab=default_tab&search_scope=MyInstitution&sortby=rank&vid=" .. settings.DatabaseName .. "&lang=en_US&offset=0");
	else
		interfaceMngr:ShowMessage("ISxN is not available from request form", "Insufficient Information");
	end
end

function SearchOCLC()
    if GetFieldValue("Transaction", "ESPNumber") ~= "" then
		PrimoVEForm.Browser:Navigate(settings.BaseVEURL .. "/discovery/search?query=any,contains," .. GetFieldValue("Transaction", "ESPNumber") .. "&tab=default_tab&search_scope=MyInstitution&sortby=rank&vid=" .. settings.DatabaseName .. "&lang=en_US&offset=0");
	else
		interfaceMngr:ShowMessage("OCLC# is not available from request form", "Insufficient Information");
	end
end



-- This function performs a standard search for LoanTitle for Loan requests and PhotoJournalTitle for Article requests.
function SearchTitle()
    if GetFieldValue("Transaction", "RequestType") == "Loan" then  
		PrimoVEForm.Browser:Navigate(settings.BaseVEURL .. "/discovery/search?query=any,contains," ..  GetFieldValue("Transaction", "LoanTitle") .. "&tab=default_tab&search_scope=MyInstitution&sortby=rank&vid=" .. settings.DatabaseName .. "&lang=en_US&offset=0");
	elseif GetFieldValue("Transaction", "RequestType") == "Article" then  
		PrimoVEForm.Browser:Navigate(settings.BaseVEURL .. "/discovery/search?query=any,contains," .. GetFieldValue("Transaction", "PhotoJournalTitle") .. "&tab=default_tab&search_scope=MyInstitution&sortby=rank&vid=" .. settings.DatabaseName .. "&lang=en_US&offset=0");
	else
		interfaceMngr:ShowMessage("The Title is not available from request form", "Insufficient Information");
	end
end

function ImportCallNumber()

		local spanElements = PrimoVEForm.Browser.WebBrowser.Document:GetElementsByTagName("span");
  
		local callNumber = '';
		local Location = '';
		local spanElement = '';
		if spanElements ~= nil then
			for i=0, spanElements.Count - 1 do
				spanElement = PrimoVEForm.Browser:GetElementByCollectionIndex(spanElements, i);
				if spanElement:GetAttribute("className") == "best-location-sub-location locations-link" then
					Location = spanElement.InnerText;
					SetFieldValue("Transaction", "Location", Location);
					break;
				end
			end

			for i=0, spanElements.Count - 1 do
				spanElement = PrimoVEForm.Browser:GetElementByCollectionIndex(spanElements, i);
				if spanElement:GetAttribute("className") == "best-location-delivery locations-link" then
					callNumber = string.sub(spanElement.InnerText,2,-2);
					SetFieldValue("Transaction", "CallNumber", callNumber);
					break;
				end
			end

			for i=0, spanElements.Count - 1 do
				spanElement = PrimoVEForm.Browser:GetElementByCollectionIndex(spanElements, i);
				if string.sub(spanElement:GetAttribute("ng-if"),24) == "callNumber" then
					callNumber = spanElement.InnerText;
					if callNumber ~= nil then
						SetFieldValue("Transaction", "CallNumber", callNumber);
						break;
					end
				end
			end
			for i=0, spanElements.Count - 1 do
				spanElement = PrimoVEForm.Browser:GetElementByCollectionIndex(spanElements, i);
				if  spanElement:GetAttribute("className") == "availability-status available" or spanElement:GetAttribute("className") == "availability-status unavailable" then
					local spanElement2 = PrimoVEForm.Browser:GetElementByCollectionIndex(spanElements, i+2);
					Location = spanElement2.InnerText;
					--interfaceMngr:ShowMessage(Location, "Test4");
					SetFieldValue("Transaction", "Location", Location);
				end
			end
			ExecuteCommand("SwitchTab", {"Detail"});
		end
end