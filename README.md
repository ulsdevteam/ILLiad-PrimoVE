# ILLiad PrimoVE integration

Original source shared by SUNY Libraries Consortium
https://slcny.libanswers.com/faq/266866

## Functionality

This diverges from the SUNY implementation in that we needed to:
* disambiguate FRBR-ized MMS IDs when the to option dedup MMS IDs is enabled in PrimoVE
    * when PrimoVE dedups MMS IDs, the barcodes of specific items displayed on the page are not necessarily related to the MMS ID presented in the page data.
* incorporate particular logic to parse the page structure to find the selected item barcode
    * we give the user the opportunity to expand view of the specific item desired to be queued for lending
* use the Partners lending-requests API to request specific materials
    * using centralized Resource Sharing lending, we were unable to make use of NCIP or NCIP Lending requests
	    * NCIP checkouts would not provide pick sheets and scanning the items would discharge, rather than route the items
		* NCIP lending requests would choose a random holding location, when known better options existed closer to our centralized resource sharing location

## Configuration

See Config.xml.sample for a template of the required configuration.  Create Config.xml with your desired values.

## Authorship, Copyright, and License

Modified by the University of Pittsburgh's University Library System, based on original work by contributors described in the PrimoVE.lua comments.
