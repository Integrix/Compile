# Copyright (C) 2007 Michael Homer
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.


# These are split out to make the code easier to manage
# The basic rule is that methods called for their return
# value go here, and those called for side-effects are
# in Freshen.rb
# More tidying to make them actual functions, or members
# of another object might be nice. However, most of them
# aren't really suited to that.
class Freshen < GoboApplication
	def getTrueCase(prog)
		if !@trueCase
			@trueCase = Hash.new
		end
		if @trueCase[prog]
			return @trueCase[prog]
		end
		# Ghostscript was renamed Artofcode-Ghostscript
		return 'Artofcode-Ghostscript' if prog.downcase=='ghostscript'
		oprog = prog.clone
		self.genTree
		self.getProgs
		self.genPackages
		found = false
		if !@recipes[prog]
			@recipes.each_key {|x|
				if x.downcase==prog.downcase
					prog = x
					found = true
					break
				end
			}
			if !found
				if !@progs[prog]
					@progs.each_key {|x|
						if x.downcase==prog.downcase
							prog = x
							found = true
							break
						end
					}
				else
					found = true
				end
			end
		else
			found = true
		end
		if found
			@trueCase[oprog] = prog
			return prog
		end
		logError "Could not find true case of #{prog}"
		return nil
	end
	
	def wordwrap(s, n)
		wwl = Screen.width-n
		(s.gsub(/.{1,#{wwl}}(?:\s|\Z)/){($& + 5.chr).gsub(/\n\005/,"\n").gsub(/\005/,"\n")}).gsub("\n","\n"+" "*(n-1)).strip
	end
	
	def setMinMax(prog, vers)
		return if !vers || vers == '' || !prog || prog=='' || prog[0,1] == '#'
		parts = vers.split(' ')
		if parts.length == 1 # Exact version, treat as >=
			vers = '>= '+vers
		end
		while vers.sub!(/(>=|==|<=|>|<) ([^ ]+)/) {|match|
			v = Version.new($2)
			if $1=='>=' || $1=='>'
				if !@minVersion[prog] || @minVersion[prog] < v
					@minVersion[prog] = v
				end
			elsif $1=='<=' || $1=='<'
				if !@maxVersion[prog] || @maxVersion[prog] > v
					@maxVersion[prog] = v
				end
			end
			''
		} do
		
		end
	end
	
	def readDependencyFile(fn)
		r = File.readlines(fn).collect {|ln|
			first, junk = ln.strip.split(' ', 2)
			setMinMax(first, junk)
			first
		}-[""]
		r.delete_if {|l|
			l==nil || l[0,1]=="#"
		}
		r
	end
	
	def getNewestAvailableVersion(prog, fr="unknown package")
		return if prog.nil?
		# Remove exceeded maxima from any consideration
		if @maxVersion[prog]
			#puts "Considering max version for #{prog} (#{@maxVersion[prog]})"
			if @recipes[prog]
				while @recipes[prog].length>0 && @recipes[prog].at(-1)>=@maxVersion[prog]
					#puts "popped #{@recipes[prog].at(-1)}"
					@recipes[prog].pop
				end
				@recipes[prog] = nil if @recipes[prog].length==0
			end
			if @packages[prog]
				while @packages[prog].length>0 && @packages[prog].at(-1)>=@maxVersion[prog]
					@packages[prog].pop
				end
				@packages[prog] = nil if @packages[prog].length==0
			end
		end
		# Patch around incorrect WindowMaker dependency file
		prog = "LibUngif" if prog=="Libungif"
		if @recipes[prog] and @packages[prog] and @config['recipes'] == 'yes' and @config['binaries']=='yes'
			newver = @recipes[prog].at(-1)
			newver = @packages[prog].at(-1) if @packages[prog].at(-1)>newver
			if @recipes[prog].at(-1)>@packages[prog].at(-1)
				newver = @recipes[prog].at(-1)
			elsif @packages[prog].at(-1)>@recipes[prog].at(-1)
				newver = @packages[prog].at(-1)
			else
				newver = @packages[prog].at(-1)
			end
		elsif @recipes[prog] and @config['recipes']=='yes'
			newver = @recipes[prog].at(-1)
		elsif @packages[prog] and @config['binaries']=='yes'
			newver = @packages[prog].at(-1)
		else
			# Try normalising the name
			np = getTrueCase(prog)
			if np.nil?
				logError "Non-existent dependency #{prog} in #{fr}. Skipping. Please consider updating the recipe."
				return Version.new('0')
			end
			if np!=prog
				self.logVerbose "Normalised dependency in #{fr}: #{prog} should be #{np}"
				return getNewestAvailableVersion(np)
			end
			# TODO: look towards removing this code altogether
			np = false
			Dir.foreach("#{@config['goboRoot']}/Programs") {|fn|
				if fn.downcase == prog.downcase && fn != prog
					self.logVerbose "Normalised dependency in #{fr}: #{prog} should be #{fn}"
					return getNewestAvailableVersion(fn)
				end
			}
			if !np && @compileConfig['compileRecipeDirs'].is_a?(Array)
				@compileConfig['compileRecipeDirs'].each {|dir|
					Dir.foreach("#{dir}") {|fn|
						if fn.downcase == prog.downcase && fn != prog
							self.logVerbose "Notice: dependency file for #{fr} has invalid entry #{prog}. Entry should read: #{fn}"
							return getNewestAvailableVersion(fn) 
						end
					}
				}
			end
		end
		if !newver
			# This log message is annoying and repeats itself.
			#self.logNormal "No data found for #{prog}. Likely cause is that it is not available in the enabled types. Data from disabled types will be used."
			@config['recipes'], tr = 'yes', @config['recipes']
			@config['binaries'], tb = 'yes', @config['binaries']
			x = getNewestAvailableVersion(prog, fr)
			@config['recipes'], @config['binaries'] = tr, tb
			return x
		end
		newver
	end
	def recipeListLines
		rlpath = "#{@config['tmpDir']}/RecipeList"
		if File.exists?(rlpath) and File.ctime(rlpath)>Time.now-@config['recipeCacheTimeout']
			return IO.readlines(rlpath)
		else
			if File.exists?(rlpath) and @config['netMode']=='offline'
				age =  Time.now-File.ctime(rlpath)
				age>1 and sage = "#{age.to_i} seconds"
				age>60 and sage = "#{(age/60).to_i} minutes"
				age>3600 and sage = "#{(age/3600).to_i} hours"
				age>86400 and sage = "#{(age/86400).to_i} days"
				age>604800 and sage = "#{(age/604800).to_i} weeks"
				self.logNormal "Updated RecipeList needed, current is #{sage} old... downloading is disabled, will proceed."
			elsif File.exists?(rlpath)
				age =  Time.now-File.ctime(rlpath)
				age>1 and sage = "#{age.to_i} seconds"
				age>60 and sage = "#{(age/60).to_i} minutes"
				age>3600 and sage = "#{(age/3600).to_i} hours"
				age>86400 and sage = "#{(age/86400).to_i} days"
				age>604800 and sage = "#{(age/604800).to_i} weeks"
				self.logNormal "Updated RecipeList needed, current is #{sage} old... will attempt download"
			elsif @config['netMode']=='offline'
				self.logNormal "RecipeList required for recipe use, downloading is off. Recipes disabled."
				@config['recipes'] = 'no'
				return Array.new
			else
				self.logNormal "RecipeList required, will attempt download to #{rlpath}"
			end
		end
		secs = 0
#		IO.popen("wget -nv -O #{rlpath} http://gobo.calica.com/recipe-store/RecipeList 2>&1") { |pipe|
		@compileConfig['getRecipeStores'].each {|store|
			File.delete("#{rlpath}.bz2") if File.exist?("#{rlpath}.bz2")
			logNormal "Downloading from store #{store}"
			IO.popen("wget -nv -O #{rlpath}.bz2 #{store}/MANIFEST.bz2 2>&1") { |pipe|
				while true
					print "\015Waiting #{@config['downloadTimeout'].to_i-secs}..."
					STDOUT.flush
					sleep 1
					secs+=1
					if secs>@config['downloadTimeout'].to_i
						self.logError "Error retrieving recipe list"
						break
					end
					(print "\015#{' '*Screen.width}\015" or break) if select([pipe],nil,nil,0)
				end
			}
			break if File.exist?("#{rlpath}.bz2")
		}
		system("bunzip2 -f #{rlpath}.bz2")
		logVerbose "Creating recipe directories"
		sudo = ""
		sudo = "sudo -u #0 " if !File.writable?(@compileConfig['compileGetRecipeDir'])
		lines = IO.readlines(rlpath)
		pb = ProgressBar.new(lines.length, 0)
		lines.each {|ln|
			pb.inc
			pb.draw if @logLevel>20
			(prog, ver, junk) = ln.split('--')
			system("#{sudo}mkdir #{@compileConfig['compileGetRecipeDir']}/#{prog}") if !File.exist?("#{@compileConfig['compileGetRecipeDir']}/#{prog}")
			system("#{sudo}mkdir #{@compileConfig['compileGetRecipeDir']}/#{prog}/#{ver}") if !File.exist?("#{@compileConfig['compileGetRecipeDir']}/#{prog}/#{ver}")
		}
		return lines
	end
	def packagesListLines
		rlpath = "#{@config['tmpDir']}/BinaryPackagesList"
		if File.exists?(rlpath) and File.ctime(rlpath)>Time.now-@config['recipeCacheTimeout']
			return IO.readlines(rlpath)
		else
			if File.exists?(rlpath)
				age =  Time.now-File.ctime(rlpath)
				age>1 and sage = "#{age.to_i} seconds"
				age>60 and sage = "#{(age/60).to_i} minutes"
				age>3600 and sage = "#{(age/3600).to_i} hours"
				age>86400 and sage = "#{(age/86400).to_i} days"
				age>604800 and sage = "#{(age/604800).to_i} weeks"
				if @config['netMode']=='offline'
					self.logNormal "Updated BinaryPackagesList needed, current is #{sage} old... downloading is disabled, will proceed."
					return IO.readlines(rlpath)
				else
					self.logNormal "Updated BinaryPackagesList needed, current is #{sage} old... will attempt download"
				end
			elsif @config['netMode']=='offline'
				self.logNormal "BinaryPackagesList is required to use binary packages, downloading is off. Binaries disabled."
				@config['binaries'] = 'no'
				return Array.new
			else
				self.logNormal "BinaryPackagesList required, will attempt download to #{rlpath}"
			end
		end
		rv = []
		@getAvailableConfig['officialPackagesLists'].each do |man|
			secs = 0
			self.logNormal "Fetching #{man}..."
			IO.popen("wget -nv -O #{rlpath}.bz2 #{man} 2>&1") { |pipe|
				while true
					print "\015Waiting #{@config['downloadTimeout'].to_i-secs}..."
					STDOUT.flush
					sleep 1
					secs+=1
					if secs>@config['downloadTimeout'].to_i
						self.logError "Error retrieving packages list"
						system("kill #{pipe.pid}")
						File.delete("#{rlpath}.bz2") if File.exist?("#{rlpath}.bz2")
						break
					end
					(print "\015#{' '*Screen.width}\015" or break) if select([pipe],nil,nil,0)
				end
			}
			if File.exists?(rlpath+".bz2")
				File.delete(rlpath) if File.exists?(rlpath)
				system "bunzip2 -f #{rlpath}.bz2"
				rv+= File.readlines(rlpath)
				return rv if @config['fetchAllPackageLists']!='yes'
			end
		end
		rv.sort!
		rv.uniq!
		f = File.open(rlpath, "w")
		f.write(rv.join(''))
		f.close
		return rv if rv.length>0
		self.logError "Unable to download packages list from any source. Binaries have been disabled."
		@config['binaries'] = false	
	end
	def produceUpdatesList(showupgrades, showdowngrades, raw = false)
		self.genTree
		self.genPackages
		self.logNormal "\033]2;Freshen: Producing updates list\007Producing updates list..."
		out = ""
		progs = Hash.new
		upgrades = downgrades = 0
		readfromcache = false
#		pcpath = File.expand_path("#{@dirname}/../../Settings/Freshen") + "/ProgramsCache.rb"
		pcpath = "#{@config['tmpDir']}/ProgramsCache.rb"
		self.getProgs
		toupdate = []
		if @config['onlyExamine'].length==0
			# This is the point the large deletion was made. If things didn't go according to plan, reinsert it.
			pb = ProgressBar.new(@progs.size,1)
			@progs.each_key {|prog|
				pb.inc
				pb.draw if @logLevel>20
				ver = @progs[prog]
				next if !ver.set?
				next if @config['except'].include?(prog)
				next if @config['exceptButCompatible'].include?(prog)
				ver = @recipes[prog].at(-1) if @config['recipes']=='yes' && @recipes[prog] && ver<@recipes[prog].at(-1)
				ver = @packages[prog].at(-1) if @config['binaries']=='yes' && @packages[prog] && ver<@packages[prog].at(-1)
				if ver>@progs[prog] and showupgrades
					toupdate.push [prog, ver]
				elsif raw
					toupdate.push [prog, ver]
				end
			}
			print " "*Screen.width if @logLevel>20
		else #onlyExamine
			logNormal "Examining only #{@config['onlyExamine'].join(', ')}"
			oe = []
			@config['onlyExamine'].each {|prog|
				prog = getTrueCase(prog) if !@progs[prog]
				if !@progs[prog]
					logError "Removed from list."
					next
				end
				oe.push prog
				ver = @progs[prog]
				ver = @recipes[prog].at(-1) if @config['recipes']=='yes' && @recipes[prog] && ver<@recipes[prog].at(-1)
				ver = @packages[prog].at(-1) if @config['binaries']=='yes' && @packages[prog] && ver<@packages[prog].at(-1)
				if true || ver>@progs[prog] and showupgrades
					toupdate.push [prog, ver]
				elsif raw
					toupdate.push [prog, ver]
				end
			}
			@config['onlyExamine'] = oe
		end
		dephash = createDepHash(toupdate)
		if @config['shallow']=='yes'
			# We have to increment the min versions of all required dependencies so they stay in
			# no matter what
			@config['onlyExamine'].each {|prog|
				@minVersion[prog] = getNewestAvailableVersion(prog)
				@maxVersion.delete(prog)
			}
		end
		return dephash if raw
		if @config['shallow']=='no' # In shallow mode, all applicable programs will have already been considered
			@progs.each {|key, value|
				getDependencies(key, value) if value && value.set?
			}
		end
		versInUse = Hash.new
		toupdate = dephash.tsort.delete_if {|x|
			nv = getNewestAvailableVersion(x) unless x.nil?||x==""
			versInUse[x] = nv
			shallowexclude = false
			shallowexclude = true if @config['shallow']=='yes' && @minVersion[x] && nv>=@minVersion[x] && !@config['onlyExamine'].include?(x)
			!(@config['force']=='yes' && @config['onlyExamine'].include?(x)) && (x.nil? || x=="" || (!@config['emptyTree'] && (@progs[x].nil? || nv.nil? || nv<=@progs[x])) || (@maxVersion[x] && nv>=@maxVersion[x]) || shallowexclude)
		}
		toupdate-=@config['exceptButCompatible']
		if @config['shallow']=='yes'
			@progs.each {|key, value|
				getDependencies(key, value) if value && value.set?
			}
			toupdate.each {|prog|
				if @maxVersion[prog] && versInUse[prog]>=@maxVersion[prog]
					logError "Warning: upgrading #{prog} past version #{@maxVersion[prog]} may cause breakage for other installed programs."
				end
			}
		end
		
		@maxVersion.each {|prog, ver|
			if ver<=@minVersion[prog]
				logError "Error: Minimum version for #{prog} is incompatible with maximum (#{@minversion[prog]}>=#{ver})."
			end
		}
		
		if toupdate.include?('Glibc') and Version.new(`uname -r`)<Version.new('2.6.20')
			self.logError("Warning: Glibc upgrade requires kernel upgrade to at least 2.6.20. Glibc has been deleted from the updates list. Some packages may fail to install because of this.");
		end
		@introducedBy = dephash.introducedBy
		toupdate
	end
	def getDependencies(prog, ver)
		if !ver.set?
			self.logError("GetDependencies called with null version")
			return []
		end
		# TODO: Should we search all recipe dirs? LocalRecipes at least might have data in it.
		if File.exists?("#{@compileConfig['compileGetRecipeDir']}/#{prog}")
			if File.exists?("#{@compileConfig['compileGetRecipeDir']}/#{prog}/#{ver}/Resources/Dependencies")
				rver = ver.to_s
			else
				cv = Version.new(0)
				Dir.foreach("#{@compileConfig['compileGetRecipeDir']}/#{prog}") {|fn|
					next if fn[0,ver.to_s.length] != ver.to_s
					nv = Version.new(fn)
					cv = nv if nv>cv
				}
				rver = cv.to_s
			end
			if File.exists?("#{@compileConfig['compileGetRecipeDir']}/#{prog}/#{rver}/Resources/Dependencies")
				# Do nothing, we're already there
			elsif rver!='none' && !File.exists?("#{@compileConfig['compileGetRecipeDir']}/#{prog}/#{rver}/Resources/Dependencies") && !File.exists?("#{@config['tmpDir']}/dependencies-#{prog}--#{ver}")
				self.logNormal("Attempting to fetch recipe dependencies for #{prog} #{rver}")
				system("GetRecipe #{prog} #{rver}")
			elsif !File.exists?("#{@compileConfig['compileGetRecipeDir']}/#{prog}/#{ver}/Resources/Dependencies") && !File.exists?("#{@config['tmpDir']}/dependencies-#{prog}--#{ver}")
				self.logNormal("Attempting to fetch recipe dependencies for #{prog} #{ver}")
				system("GetRecipe #{prog} #{ver}")
				rver = "#{ver}"
			end
			
			if File.exists?("#{@compileConfig['compileGetRecipeDir']}/#{prog}/#{rver}/Resources/Dependencies")
				return readDependencyFile("#{@compileConfig['compileGetRecipeDir']}/#{prog}/#{rver}/Resources/Dependencies")
			end
		end
		# Try fetching package dependencies
		if !File.exists?("#{@config['tmpDir']}/dependencies-#{prog}--#{ver}")
			self.logNormal("Attempting to fetch package dependencies for #{prog} #{ver}")
			@getAvailableConfig['officialPackagesLists'].each {|repo|
				repo = repo[0, repo.length-12]
				system("wget -q -O #{@config['tmpDir']}/dependencies-#{prog}--#{ver} #{repo}dependencies/#{prog.downcase}--#{ver}--#{@config['arch']}")
				break if File.exists?("#{@config['tmpDir']}/dependencies-#{prog}--#{ver}")
			}
		end
		if File.exists?("#{@config['tmpDir']}/dependencies-#{prog}--#{ver}")
			return readDependencyFile("#{@config['tmpDir']}/dependencies-#{prog}--#{ver}")
		else
			system("touch #{@config['tmpDir']}/dependencies-#{prog}--#{ver}")
		end
		return []
	end
end