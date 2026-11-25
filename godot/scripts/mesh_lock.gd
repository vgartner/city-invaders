class_name MeshLock
extends RefCounted
## One thread at a time reads a mesh's triangles (create_trimesh_shape,
## create_trimesh_collision, get_faces). A Mesh keeps the triangles it once
## worked out, and the same Mesh is in many models (a shop module stands
## twenty times in a map): two threads asking the same one - two shape jobs
## of the open world, or a job and the main thread placing the next
## landmark - crashed the game (9 of 20 starts of the Centro).
##
## A worker thread uses lock() / unlock(). The main thread uses take() /
## give(): a worker reading a mesh sleeps until the main thread has served
## the rendering server, so a main thread that slept on the lock would wait
## for a worker that waits for it; take() keeps serving while it waits.

static var _lock := Mutex.new()


static func lock() -> void:
	_lock.lock()


static func unlock() -> void:
	_lock.unlock()


static func take() -> void:
	while not _lock.try_lock():
		RenderingServer.force_sync()
		OS.delay_usec(100)


static func give() -> void:
	_lock.unlock()
