/**************************************** ****************************************
 * Copyright 2010 Massive Interactive. All rights reserved.
 * 
 * Redistribution and use in source and binary forms, with or without modification, are
 * permitted provided that the following conditions are met:
 * 
 *    1. Redistributions of source code must retain the above copyright notice, this list of
 *       conditions and the following disclaimer.
 * 
 *    2. Redistributions in binary form must reproduce the above copyright notice, this list
 *       of conditions and the following disclaimer in the documentation and/or other materials
 *       provided with the distribution.
 * 
 * THIS SOFTWARE IS PROVIDED BY MASSIVE INTERACTIVE ``AS IS'' AND ANY EXPRESS OR IMPLIED
 * WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
 * FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL MASSIVE INTERACTIVE OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
 * ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
 * NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
 * ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 * 
 * The views and conclusions contained in the software and documentation are those of the
 * authors and should not be interpreted as representing official policies, either expressed
 * or implied, of Massive Interactive.
 */
package massive.munit.command;

import massive.munit.Config;
import haxe.Http;
import haxe.io.Eof;
import massive.neko.io.File;
import massive.neko.io.FileSys;
import massive.haxe.util.RegExpUtil;
import massive.munit.client.HTTPClient;
import neko.io.Process;
import neko.vm.Thread;
import neko.vm.Mutex;
import neko.Lib;
import neko.Sys;
import neko.io.Path;
import massive.haxe.log.Log;
import massive.haxe.util.TemplateUtil;
import massive.munit.ServerMain;
import massive.munit.util.MathUtil;

class RunCommand extends MUnitCommand
{	
	public static inline var DEFAULT_SERVER_TIMEOUT_SEC:Int = 30;

	private var files:Array<File>;
	
	private var browser:String;

	private var reportDir:File;
	private var reportRunnerDir:File;
	private var reportTestDir:File;
	
	private var tmpDir:File;
	private var tmpRunnerDir:File;
	private var binDir:File;
	
	private var targetTypes:Array<TargetType>;
	
	private var killBrowser:Bool;
	private var indexPage:File;
	private var nekoFile:File;
	private var hasBrowserTests:Bool;
	private var hasNekoTests:Bool;
	private var serverTimeoutTimeSec:Int;
	
	public function new():Void
	{
		super();
		killBrowser = false;

		// TODO: Configure this through args to munit. ms 4/8/11
		serverTimeoutTimeSec = DEFAULT_SERVER_TIMEOUT_SEC;
	}
	
	override public function initialise():Void
	{
		getTargetTypes();
		locateBinDir();
		gatherTestRunnerFiles();
		locateReportDir();
		checkForCustomBrowser();
		checkForBrowserKeepAliveFlag();
		generateTestRunnerPages();
	}
	
	function getTargetTypes()
	{
		targetTypes = new Array();

		if (console.getOption("swf") == "true")
		{
			targetTypes.push(TargetType.swf9);
			targetTypes.push(TargetType.swf);
		}
		else
		{
			if (console.getOption("as2") == "true")
				targetTypes.push(TargetType.swf);
			if (console.getOption("as3") == "true")
				targetTypes.push(TargetType.swf9);
		}
		if (console.getOption("js") == "true")
			targetTypes.push(TargetType.js);
		if (console.getOption("neko") == "true")
			targetTypes.push(TargetType.neko);

		if (targetTypes.length == 0)
			targetTypes = config.targetTypes.concat([]);
	}
	
	function locateBinDir()
	{
		var binPath:String = console.getNextArg();
	
		if (binPath == null)
		{
			binDir = config.bin;
			
			if (binDir == null)
				error("Default bin directory is not set. Please run munit config.");
			
			if (!binDir.exists)
				binDir.createDirectory();
		}
		else
		{
			binDir = File.create(binPath, console.dir);

			if (!binDir.exists)
				binDir.createDirectory();
		}
		
		Log.debug("binPath: " + binDir);
	}
	
	function gatherTestRunnerFiles()
	{
		if (binDir.isDirectory)
		{
			var reg:EReg = ~/_test\.(n|swf|js)$/;
			
			var tempFiles:Array<File> = binDir.getDirectoryListing(reg);
			
			files = []; 
	
			for (file in tempFiles)
			{
				for (type in targetTypes)
				{
					if (file.extension == "swf")
					{
						if (type == TargetType.swf9 && file.fileName.indexOf("as3_test.swf") != -1)
							files.push(file);
						else if (type == TargetType.swf && file.fileName.indexOf("as2_test.swf") != -1)
							files.push(file);
					}
					else if (type == TargetType.js && file.extension == "js")
						files.push(file);
					else if (type == TargetType.neko && file.extension == "n")
					{
						files.push(file);
						hasNekoTests = true;
					}
				}
			}
			
			Log.debug(files.length + " targets");
			
			for (file in files)
				Log.debug("   " + file);
		}
	}

	function locateReportDir()
	{
		var reportPath:String = console.getNextArg();
		
		if (reportPath == null)
		{
			reportDir = config.report;
			
			if (reportDir == null)
				error("Default report directory is not set. Please run munit config.");
			if (!reportDir.exists)
				reportDir.createDirectory();
		}
		else
		{
			reportDir = File.create(reportPath, console.dir);
			
			if(!reportDir.exists)
				reportDir.createDirectory();
		}
		
		Log.debug("report: " + reportDir);
	}

	function checkForCustomBrowser()
	{
		reportRunnerDir = reportDir.resolveDirectory("test-runner");
		reportTestDir = reportDir.resolveDirectory("test");
		
		var b:String = console.getOption("browser");
		if (b != null && b != "true")
			browser = b;
		
		Log.debug("browser: " + browser);
	}
	
	function checkForBrowserKeepAliveFlag()
	{
		if(console.getOption("kill-browser") != null)
		{
			killBrowser = true;
			Log.debug("killBrowser? " + killBrowser);
		}		
	}
	
	function generateTestRunnerPages()
	{
		resetOutputDirectories();
		var pageNames = [];
		for (file in files)
		{			
			if (file.extension == 'js' || file.extension == 'swf')
			{
				var pageName = file.fileName.substr(0, -file.extension.length) + "html";
				var pageContent = TemplateUtil.getTemplate(file.extension + "_runner-html", {runnerName:file.fileName});
				var runnerPage = reportRunnerDir.resolvePath(pageName);
				
				runnerPage.writeString(pageContent);
				pageNames.push(pageName);
				hasBrowserTests = true;
			}
			else if (file.extension == 'n')
			{
				hasNekoTests = true;
				nekoFile = file;
			}
		}
		
		var frameCols = "";
		var frames = "";
		var frameTitles = "";
		var colCount = Math.round(100 / pageNames.length);
		for (pageName in pageNames)
		{
			frameCols += "*,";
			frameTitles += '<td width="' + colCount + '%">' + pageName.substr(0, pageName.indexOf('_')).toUpperCase() + '</td>';
			frames += '<frame src="' + pageName + '" scrolling="no" NORESIZE/>\n';
		}
		
		frameCols = frameCols.substr(0, -1);			
		
		var headerContent = TemplateUtil.getTemplate("target-headers-html", { targetHeaderTitles:frameTitles } );
		var headerPage = reportRunnerDir.resolvePath("target_headers.html");
		headerPage.writeString(headerContent, true);
		
		var pageContent = TemplateUtil.getTemplate("runner-html", {killBrowser:killBrowser, testCount:pageNames.length, frames:frames, frameCols:frameCols});
		indexPage = reportRunnerDir.resolvePath("index.html");
		indexPage.writeString(pageContent, true);
		
		var resourceDir:File = console.originalDir.resolveDirectory("resource");
		binDir.copyTo(reportRunnerDir);
		resourceDir.copyTo(reportRunnerDir);
	}
	
	override public function execute():Void
	{
		var errors:Array<String> = new Array();
		
		FileSys.setCwd(console.originalDir.nativePath);
		var serverExitCode:Int = 0;
		
		tmpDir = File.current.resolveDirectory("tmp");
		if (tmpDir.exists)
			tmpDir.deleteDirectoryContents(RegExpUtil.SVN_REGEX, true);
		
		tmpRunnerDir = tmpDir.resolveDirectory("runner");
		reportRunnerDir.copyTo(tmpRunnerDir);

		var serverProcess = new Process("nekotools", ["server"]);
		var resultMonitor = Thread.create(monitorResults);
		
		resultMonitor.sendMessage(Thread.current());
		resultMonitor.sendMessage(serverProcess);
		resultMonitor.sendMessage(serverTimeoutTimeSec);
		
		if (hasNekoTests)
			launchNeko(nekoFile);

		if (hasBrowserTests)
			launchFile(indexPage);
		else
			resultMonitor.sendMessage("quit");
		
		var complete = Thread.readMessage(true);

		serverProcess.kill();

//		var t = Sys.time();

		if (reportTestDir.exists)
			reportTestDir.deleteDirectoryContents();

		tmpRunnerDir.deleteDirectory();
		tmpDir.copyTo(reportTestDir);
		tmpDir.deleteDirectory(true);
		FileSys.setCwd(console.dir.nativePath);
//		print(Sys.time() - t); // 4+ secs on mac

	}
	
	private function monitorResults():Void
	{
		var mainThread = Thread.readMessage(true);
		var serverProcess = Thread.readMessage(true);
		var serverTimeoutTimeSec = Thread.readMessage(true);
		var testRunCount = 0;
		var testPassCount = 0;
		var testFailCount = 0;
		var testErrorCount = 0;
		
		var startTime = Sys.time();
		var lastResultTime = startTime;
		var serverHung = false;

		if (serverTimeoutTimeSec == null || serverTimeoutTimeSec < 10)
			serverTimeoutTimeSec = DEFAULT_SERVER_TIMEOUT_SEC;
		
		// Note: Tried using FileSystem.stat mod date to see changes in results.txt but 
		//       writes are too quick so using line count instead.
		var fileName = tmpDir.nativePath + "results.txt";
		var file = null;
		var lineCount = 0;
		var platformMap = new Hash<Bool>(); 
		do
		{
			if ((Sys.time() - lastResultTime) > serverTimeoutTimeSec)
			{
				serverHung = true;
				break;
			}
			if (Thread.readMessage(false) == "quit")
				break;
			
			if (!neko.FileSystem.exists(fileName))
				continue;
			
			if (file == null)
				file = tmpDir.resolvePath("results.txt");
			
			var contents = "";
			try {
				contents = file.readString();
			}
			catch (e:Dynamic) {
				Sys.sleep(0.1);
				continue;
			}
				
			var lines = contents.split("\n");
			lines.pop();
			
			if (lines.length > lineCount)
			{
				var i = lineCount;
				lineCount = lines.length;

				if ( i < lineCount)
					lastResultTime = Sys.time();
				
				while (i < lineCount)
				{
					var line = lines[i++];

					if (line != ServerMain.END)
					{
						if (checkIfTestPassed(line))
							testPassCount++;
						else if (checkIfTestFailed(line))
							testFailCount++;
						else
							testErrorCount++;
						
						var parts = line.split("under ");
						if (parts.length > 1)
						{
							var platform = parts[1].split(" ")[0];
							platformMap.set(platform, true);

							print(line);
						}
					}
				}
								
				if (lines[lineCount - 1] == ServerMain.END)
				{
					lineCount--;
					break;
				}
			}
		}
		while (true);


		var platformCount = Lambda.count(platformMap);
		
		print("------------------------------");
		print("PLATFORMS TESTED: " + platformCount + ", PASSED: " + testPassCount + ", FAILED: " + testFailCount + ", ERRORS: " + testErrorCount + ", TIME: " + MathUtil.round(Sys.time() - startTime, 5));

		if (serverHung)
			print("ERROR: Local results server appeared to hang so test reporting was cancelled.");

		mainThread.sendMessage("done");
	}
	
	private function getTargetName(result:String):String
	{
		return result.split("under ")[1].split(" using")[0];
	}
	
	private function checkIfTestPassed(result:String):Bool
	{
		return result.indexOf(ServerMain.PASSED) != -1;
	}
	
	private function checkIfTestFailed(result:String):Bool
	{
		return result.indexOf(ServerMain.FAILED) != -1;
	}
	
	private function resetOutputDirectories():Void
	{
		if (!reportRunnerDir.exists) 
			reportRunnerDir.createDirectory();
		else 
			reportRunnerDir.deleteDirectoryContents(RegExpUtil.SVN_REGEX, true);

		if (!reportTestDir.exists) 
			reportTestDir.createDirectory();
		else 
			reportTestDir.deleteDirectoryContents(RegExpUtil.SVN_REGEX, true);			
	}
	
	private function launchFile(file:File):Int
	{
		var targetLocation:String  = HTTPClient.DEFAULT_SERVER_URL + "/tmp/runner/" + file.fileName;		
		var parameters:Array<String> = [];

		if (FileSys.isWindows) 
		{
			parameters.push("start");
			if (browser != null) 
				parameters.push(browser);
		}
		else
		{
			parameters.push("open");
			if (browser != null) 
				parameters.push("-a " + browser);
		}
		
		parameters.push(targetLocation);

		var exitCode:Int = neko.Sys.command(parameters.join(" "));
		if (exitCode > 0)
			neko.Lib.println("Error running " + targetLocation);
		
		return exitCode;
	}
	
	private function launchNeko(file:File):Int
	{
		var reportRunnerFile:File = reportRunnerDir.resolvePath(file.fileName);
		file.copyTo(reportRunnerFile);
		
		var parameters:Array<String> = [];
		parameters.push("neko");
		parameters.push('"' + reportRunnerFile.nativePath + '"');

		neko.Lib.println(parameters.join(" "));

		var exitCode:Int = neko.Sys.command(parameters.join(" "));
		if (exitCode > 0)
			neko.Lib.println("Error running " + file);
		
		return exitCode;
	}
}
