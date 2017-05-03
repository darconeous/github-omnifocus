#!/usr/bin/env ruby

require 'bundler/setup'
Bundler.require(:default)

require 'rb-scpt'
require 'yaml'
require 'net/http'
require 'pathname'
require 'octokit'

Octokit.auto_paginate = true

def get_opts
	if  File.file?(ENV['HOME']+'/.ghofsync.yaml')
		config = YAML.load_file(ENV['HOME']+'/.ghofsync.yaml')
	else config = YAML.load <<-EOS
	#YAML CONFIG EXAMPLE
---
github:
	username: ''
	password: ''
omnifocus:
	context:  'Office'
	project:  'GitHub'
	flag: true
EOS
	end

	return Trollop::options do
		banner ""
		banner <<-EOS
		GitHub OmniFocus Sync Tool

Usage:
			 ghofsync [options]

KNOWN ISSUES:
			* With long names you must use an equal sign ( i.e. --hostname=test-target-1 )

---
EOS
	version 'ghofsync 1.1.0'
		opt :username,  'github Username',        :type => :string,   :short => 'u', :required => false,   :default => config["github"]["username"]
		opt :password,  'github Password',        :type => :string,   :short => 'p', :required => false,   :default => config["github"]["password"]
		opt :oauth,  	  'github oauth token',      :type => :string,   :short => 'o', :required => false,   :default => config["github"]["oauth"]
		opt :context,   'OF Default Context',   :type => :string,   :short => 'c', :required => false,   :default => config["omnifocus"]["context"]
		opt :project,   'OF Default Project',   :type => :string,   :short => 'r', :required => false,   :default => config["omnifocus"]["project"]
		opt :flag,      'Flag tasks in OF',     :type => :boolean,  :short => 'f', :required => false,   :default => config["omnifocus"]["flag"]
		opt :quiet,     'Disable output',       :type => :boolean,   :short => 'q',                      :default => true
	end
end

def get_issues
	github_issues = Hash.new

	if $opts[:username] && $opts[:password]
		client = Octokit::Client.new(:login => $opts[:username], :password => $opts[:password])
		client.user.login
	elsif $opts[:oauth]
		client = Octokit::Client.new :access_token => $opts[:oauth]
		client.user.login
	else
		puts "No username/password or oauth token found!"
	end

	client.list_issues.each do |issue|
		number    = issue.number
		project   = issue.repository.full_name.split("/").last
		issue_id = "#{project}-##{number}"

		github_issues[issue_id] = issue
		puts "Assigned " + issue_id
	end

	#client.paginate("issues", { :query => "q=is%3Aopen%20review-requested%3A#{$opts[:username]}"}).each do |issue|
	#client.search_issues("is:open review-requested:#{$opts[:username]}").each do |issue|
	#puts client.paginate("search/issues", { :q => "is:open review-requested:#{$opts[:username]}"})
	#client.paginate("search/issues", { :q => "is:open review-requested:#{$opts[:username]}"}).each do |data|
	client.search_issues("is:open review-requested:#{$opts[:username]}").each do |data|
		if data[0] == :items
			data[1].each do |issue|
				number    = issue.number
				project   = issue.repository_url.split("/").last
				issue_id = "#{project}-##{number}"
				github_issues[issue_id] = issue
				puts "Review Requested " + issue_id
			end
		end
	end
	return github_issues
end


# This method adds a new Task to OmniFocus based on the new_task_properties passed in
def add_task(omnifocus_document, new_task_properties)
	# If there is a passed in OF project name, get the actual project object
	if new_task_properties['project']
		proj_name = new_task_properties["project"]
		proj = omnifocus_document.flattened_tasks[proj_name]
	end

	# Check to see if there's already an OF Task with that name in the referenced Project
	# If there is, just stop.
	name   = new_task_properties["name"]
	name   = name.slice(0..(name.index(':')+1))
	#exists = proj.tasks.get.find { |t| t.name.get.force_encoding("UTF-8") == name }
	# You can un-comment the line below and comment the line above if you want to search your entire OF document, instead of a specific project.
	exists = omnifocus_document.flattened_tasks.get.find { |t| t.name.get.force_encoding("UTF-8").start_with?(name) }
	return false if exists

	# If there is a passed in OF context name, get the actual context object
	if new_task_properties['context']
		ctx_name = new_task_properties["context"]
		ctx = omnifocus_document.flattened_contexts[ctx_name]
	end

	# Do some task property filtering.  I don't know what this is for, but found it in several other scripts that didn't work...
	tprops = new_task_properties.inject({}) do |h, (k, v)|
		h[:"#{k}"] = v
		h
	end

	# Remove the project property from the new Task properties, as it won't be used like that.
	tprops.delete(:project)
	# Update the context property to be the actual context object not the context name
	tprops[:context] = ctx if new_task_properties['context']

	# You can uncomment this line and comment the one below if you want the tasks to end up in your Inbox instead of a specific Project
	new_task = omnifocus_document.make(:new => :inbox_task, :with_properties => tprops)

	# Make a new Task in the Project
	#proj.make(:new => :task, :with_properties => tprops)

	puts "Created task " + tprops[:name]
	return true
end

# This method is responsible for getting your assigned GitHub Issues and adding them to OmniFocus as Tasks
def add_github_issues_to_omnifocus (omnifocus_document)
	# Get the open Jira issues assigned to you
	results = get_issues
	if results.nil?
		puts "No results from GitHub"
		exit
	end

	# Iterate through resulting issues.
	results.each do |issue_id, issue|

		pr        = issue["pull_request"] && !issue["pull_request"]["diff_url"].nil?
		number    = issue.number
		project   = issue.repository_url.split("/").last
		issue_id = "#{project}-##{number}"
		title     = "#{issue_id}: #{pr ? "[PR] " : ""}#{issue["title"]}"
		url       = issue.html_url
                #"https://github.com/#{issue.repository.full_name}/issues/#{number}"
		note      = "#{url}\n\n#{issue["body"]}"

		task_name = title
		# Create the task notes with the GitHub Issue URL and issue body
		task_notes = note

		# Build properties for the Task
		@props = {}
		@props['name'] = task_name
		@props['project'] = $opts[:project]
		@props['context'] = $opts[:context]
		@props['note'] = task_notes
		@props['flagged'] = $opts[:flag]
		add_task(omnifocus_document, @props)
	end
end

def mark_resolved_github_issues_as_complete_in_omnifocus (omnifocus_document)
	# get tasks from the project
	ctx = omnifocus_document.flattened_contexts[$opts[:context]]
	ctx.tasks.get.find.each do |task|
		if !task.completed.get && task.note.get.lines.first.match(/https:\/\/github\.com\/.*\/(issues|pull)\/.*/i)
			note = task.note.get
			repo, type, number = note.lines.first.match(/https:\/\/github\.com\/(.*)\/(issues|pull)\/(.*)/i).captures

			puts "Analyzing " + type + " " + repo + "#" + number

			if $opts[:username] && $opts[:password]
				client = Octokit::Client.new(:login => $opts[:username], :password => $opts[:password])
				client.user.login
			elsif $opts[:oauth]
				client = Octokit::Client.new :access_token => $opts[:oauth]
				client.user.login
			else
				puts "No username/password or oauth token found!"
			end

			issue = client.issue(repo, number)
			if issue != nil
				if issue.state == 'closed' || issue.state == 'merged'
					# if resolved, mark it as complete in OmniFocus
					if task.completed.get != true
						task.completed.set(true)
						number    = issue.number
						puts "Marked task completed " + number.to_s
					end
				end

				# Check to see if the GitHub issue has been unassigned or assigned to someone else, if so delete it.
				# It will be re-created if it is assigned back to you.
				if ! issue.assignee
					#omnifocus_document.delete task
				else
					assignee = issue.assignee.login.downcase
					if assignee != $opts[:username].downcase
						#omnifocus_document.delete task
					end
				end
			end
		end
	end
end

def app_is_running(app_name)
	`ps aux` =~ /#{app_name}/ ? true : false
end

def get_omnifocus_document
	return Appscript.app.by_name("OmniFocus").default_document
end



def main ()
	if app_is_running("OmniFocus")
		$opts = get_opts
		omnifocus_document = get_omnifocus_document
		add_github_issues_to_omnifocus(omnifocus_document)
		mark_resolved_github_issues_as_complete_in_omnifocus(omnifocus_document)
	end
end

main
