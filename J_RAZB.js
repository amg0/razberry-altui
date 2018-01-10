//# sourceURL=J_ALTUI.js
// This program is free software: you can redistribute it and/or modify
// it under the condition that it is for private or home useage and 
// this whole comment is reproduced in the source code file.
// Commercial utilisation is not authorized without the appropriate
// written agreement from amg0 / alexis . mermet @ gmail . com
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. 

//-------------------------------------------------------------
// RAZB  Plugin javascript Tabs
//-------------------------------------------------------------
var razb_Svs = 'urn:upnp-org:serviceId:razb1';
var ip_address = data_request_url;

//-------------------------------------------------------------
// Utilities Javascript
//-------------------------------------------------------------
if (typeof String.prototype.format == 'undefined') {
	String.prototype.format = function()
	{
	   var content = this;
	   for (var i=0; i < arguments.length; i++)
	   {
			var replacement = new RegExp('\\{' + i + '\\}', 'g');	// regex requires \ and assignment into string requires \\,
			// if ($.type(arguments[i]) === "string")
				// arguments[i] = arguments[i].replace(/\$/g,'$');
			content = content.replace(replacement, arguments[i]);  
	   }
	   return content;
	};
};


String.prototype.htmlEncode = function()
{
   var value = this;
   return $('<div/>').text(value).html();
}
 
String.prototype.htmlDecode= function()
{
	var value = this;
    return $('<div/>').html(value).text();
}

function isFunction(x) {
  return Object.prototype.toString.call(x) == '[object Function]';
}


//-------------------------------------------------------------
// Device TAB : Donate
//-------------------------------------------------------------	
function razb_Donate(deviceID) {
	// var htmlDonate='For those who really like this plugin and feel like it, you can donate what you want here on Paypal. It will not buy you more support not any garantee that this can be maintained or evolve in the future but if you want to show you are happy and would like my kids to transform some of the time I steal from them into some <i>concrete</i> returns, please feel very free ( and absolutely not forced to ) to donate whatever you want.  thank you ! ';
	// htmlDonate+='<form action="https://www.paypal.com/cgi-bin/webscr" method="post" target="_top"><input type="hidden" name="cmd" value="_donations"><input type="hidden" name="business" value="alexis.mermet@free.fr"><input type="hidden" name="lc" value="FR"><input type="hidden" name="item_name" value="Alexis Mermet"><input type="hidden" name="item_number" value="RAZB"><input type="hidden" name="no_note" value="0"><input type="hidden" name="currency_code" value="EUR"><input type="hidden" name="bn" value="PP-DonationsBF:btn_donateCC_LG.gif:NonHostedGuest"><input type="image" src="https://www.paypalobjects.com/en_US/FR/i/btn/btn_donateCC_LG.gif" border="0" name="submit" alt="PayPal - The safer, easier way to pay online!"><img alt="" border="0" src="https://www.paypalobjects.com/fr_FR/i/scr/pixel.gif" width="1" height="1"></form>';
	// var html = '<div>'+htmlDonate+'</div>';
	// set_panel_html(html);
}

//-------------------------------------------------------------
// Device TAB : Settings
//-------------------------------------------------------------	

function razb_Settings(deviceID) {
	// first determine if it is a child device or not
	//var device = findDeviceIdx(deviceID);
	//var debug  = get_device_state(deviceID,  razb_Svs, 'Debug',1);
	//var root = (device!=null) && (jsonp.ud.devices[device].id_parent==0);
	var style='	<style>\
	  </style>';

	var html =
		style+
		'<div class="pane" id="pane"> '+ 
		'<table class="razb_table" id="razb_table">'+
		'</table>'+
		'</div>' ;

	//html = html + '<button id="button_save" type="button">Save</button>'
	set_panel_html(html);
}

//-------------------------------------------------------------
// Variable saving ( log , then full save )
//-------------------------------------------------------------
function saveVar(deviceID,  service, varName, varVal, reload)
{
	//set_device_state (deviceID, service, varName, varVal, 0);	// only updated at time of luup restart
	set_device_state (deviceID, razb_Svs, varName, varVal, (reload==true) ? 0 : 1);	// lost in case of luup restart
}

