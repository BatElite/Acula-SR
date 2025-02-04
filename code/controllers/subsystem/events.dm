SUBSYSTEM_DEF(events)
	name = "Events"
	init_order = INIT_ORDER_EVENTS
	runlevels = RUNLEVEL_GAME

	var/list/control = list() //list of all datum/round_event_control. Used for selecting events based on weight and occurrences.
	var/list/running = list() //list of all existing /datum/round_event
	var/list/currentrun = list()

	var/scheduled = 0 //The next world.time that a naturally occuring random event can be selected.
	var/frequency_lower = 1800 //3 minutes lower bound.
	var/frequency_upper = 6000 //10 minutes upper bound. Basically an event will happen every 3 to 10 minutes.

	var/list/holidays //List of all holidays occuring today or null if no holidays
	var/wizardmode = FALSE

	var/list/previously_run = list() //SKYRAT EDIT ADDITION

/datum/controller/subsystem/events/Initialize()
	for(var/type in typesof(/datum/round_event_control))
		var/datum/round_event_control/E = new type()
		if(!E.typepath)
			continue //don't want this one! leave it for the garbage collector
		control += E //add it to the list of all events (controls)
	reschedule()
	getHoliday()
	// SKYRAT EDIT ADDITION
	if(CONFIG_GET(flag/low_chaos_event_system))
		reschedule_low_chaos()
	frequency_lower = CONFIG_GET(number/event_frequency_lower)
	frequency_upper = CONFIG_GET(number/event_frequency_upper)
	// SKYRAT EDIT END
	return SS_INIT_SUCCESS

/datum/controller/subsystem/events/fire(resumed = FALSE)
	if(!resumed)
		checkEvent() //only check these if we aren't resuming a paused fire
		src.currentrun = running.Copy()

	//cache for sanic speed (lists are references anyways)
	var/list/currentrun = src.currentrun

	while(currentrun.len)
		var/datum/thing = currentrun[currentrun.len]
		currentrun.len--
		if(thing)
			thing.process(wait * 0.1)
		else
			running.Remove(thing)
		if (MC_TICK_CHECK)
			return

//checks if we should select a random event yet, and reschedules if necessary
/datum/controller/subsystem/events/proc/checkEvent()
	// SKYRAT EDIT ADDITION
	if(scheduled_low_chaos <= world.time && CONFIG_GET(flag/low_chaos_event_system))
		triger_low_chaos_event()
	// SKYRAT EDIT END
	if(scheduled <= world.time)
		//spawnEvent() //SKYRAT EDIT CHANGE
		if(CONFIG_GET(flag/events_use_random))
			spawnEvent()
		else
			if(CONFIG_GET(flag/events_public_voting))
				start_player_vote_chaos(FALSE)
			else
				if(CONFIG_GET(flag/admin_event_uses_chaos))
					start_vote_admin_chaos()
				else
					start_vote_admin()
		// SKYRAT EDIT END
		reschedule()

//decides which world.time we should select another random event at.
/datum/controller/subsystem/events/proc/reschedule()
	// SKYRAT EDIT CHANGE
	var/next_event_time = rand(frequency_lower, max(frequency_lower, frequency_upper))
	if(CONFIG_GET(flag/low_chaos_event_system))
		reschedule_low_chaos(next_event_time / 2)
	scheduled = world.time + next_event_time
	// SKYRAT EDIT END


//selects a random event based on whether it can occur and it's 'weight'(probability)
/datum/controller/subsystem/events/proc/spawnEvent(threat_override = FALSE) //SKYRAT EDIT CHANGE
	set waitfor = FALSE //for the admin prompt
	if(!CONFIG_GET(flag/allow_random_events))
		return

	var/players_amt = get_active_player_count(alive_check = 1, afk_check = 1, human_check = 1)
	// Only alive, non-AFK human players count towards this.
	var/sum_of_weights = 0
	for(var/datum/round_event_control/E in control)
		if(!E.can_spawn_event(players_amt))
			continue
		//SKYRAT EDIT ADDITION
		if(threat_override && !E.alert_observers)
			continue
		//SKYRAT EDIT END
		if(E.weight < 0) //for round-start events etc.
			var/res = TriggerEvent(E)
			if(res == EVENT_INTERRUPTED)
				continue //like it never happened
			if(res == EVENT_CANT_RUN)
				return
		sum_of_weights += E.weight

	sum_of_weights = rand(0,sum_of_weights) //reusing this variable. It now represents the 'weight' we want to select

	for(var/datum/round_event_control/E in control)
		if(!E.can_spawn_event(players_amt))
			continue
		sum_of_weights -= E.weight

		if(sum_of_weights <= 0) //we've hit our goal
			if(TriggerEvent(E))
				return

/datum/controller/subsystem/events/proc/TriggerEvent(datum/round_event_control/E)
	. = E.preRunEvent()
	if(. == EVENT_CANT_RUN)//we couldn't run this event for some reason, set its max_occurrences to 0
		E.max_occurrences = 0
	else if(. == EVENT_READY)
		E.runEvent(random = TRUE)

/*
//////////////
// HOLIDAYS //
//////////////
//Uncommenting ALLOW_HOLIDAYS in config.txt will enable holidays

//It's easy to add stuff. Just add a holiday datum in code/modules/holiday/holidays.dm
//You can then check if it's a special day in any code in the game by doing if(SSevents.holidays["Groundhog Day"])

//You can also make holiday random events easily thanks to Pete/Gia's system.
//simply make a random event normally, then assign it a holidayID string which matches the holiday's name.
//Anything with a holidayID, which isn't in the holidays list, will never occur.

//Please, Don't spam stuff up with stupid stuff (key example being april-fools Pooh/ERP/etc),
//And don't forget: CHECK YOUR CODE!!!! We don't want any zero-day bugs which happen only on holidays and never get found/fixed!

//////////////////////////////////////////////////////////////////////////////////////////////////////////
//ALSO, MOST IMPORTANTLY: Don't add stupid stuff! Discuss bonus content with Project-Heads first please!//
//////////////////////////////////////////////////////////////////////////////////////////////////////////
*/

//sets up the holidays and holidays list
/datum/controller/subsystem/events/proc/getHoliday()
	if(!CONFIG_GET(flag/allow_holidays))
		return // Holiday stuff was not enabled in the config!
	for(var/H in subtypesof(/datum/holiday))
		var/datum/holiday/holiday = new H()
		var/delete_holiday = TRUE
		for(var/timezone in holiday.timezones)
			var/time_in_timezone = world.realtime + timezone HOURS

			var/YYYY = text2num(time2text(time_in_timezone, "YYYY")) // get the current year
			var/MM = text2num(time2text(time_in_timezone, "MM")) // get the current month
			var/DD = text2num(time2text(time_in_timezone, "DD")) // get the current day
			var/DDD = time2text(time_in_timezone, "DDD") // get the current weekday

			if(holiday.shouldCelebrate(DD, MM, YYYY, DDD))
				holiday.celebrate()
				LAZYSET(holidays, holiday.name, holiday)
				delete_holiday = FALSE
				break
		if(delete_holiday)
			qdel(holiday)

	if(holidays)
		holidays = shuffle(holidays)
		// regenerate station name because holiday prefixes.
		set_station_name(new_station_name())
		world.update_status()

/datum/controller/subsystem/events/proc/toggleWizardmode()
	wizardmode = !wizardmode
	message_admins("Summon Events has been [wizardmode ? "enabled, events will occur every [SSevents.frequency_lower / 600] to [SSevents.frequency_upper / 600] minutes" : "disabled"]!")
	log_game("Summon Events was [wizardmode ? "enabled" : "disabled"]!")


/datum/controller/subsystem/events/proc/resetFrequency()
	frequency_lower = initial(frequency_lower)
	frequency_upper = initial(frequency_upper)
