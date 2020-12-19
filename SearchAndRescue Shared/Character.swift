/*
 Copyright (C) 2018 Apple Inc. All Rights Reserved.
 See LICENSE.txt for this sample’s licensing information
 
 Abstract:
 This class manages the main character, including its animations, sounds and direction.
*/

import Foundation
import SceneKit
import simd

// Returns plane / ray intersection distance from ray origin.
func planeIntersect(planeNormal: float3, planeDist: Float, rayOrigin: float3, rayDirection: float3) -> Float {
    return (planeDist - simd_dot(planeNormal, rayOrigin)) / simd_dot(planeNormal, rayDirection)
}

class Character: NSObject {
    
    static private let speedFactor: CGFloat = 2.0
    static private let stepsCount = 10

    static private let initialPosition = float3(0.1, -0.2, 0)
    
    // some constants
    static private let gravity = Float(0.004)
    static private let jumpImpulse = Float(0.1)
    static private let minAltitude = Float(-10)
    static private let enableFootStepSound = true
    static private let collisionMargin = Float(0.04)
    static private let modelOffset = float3(0, -collisionMargin, 0)
    static private let collisionMeshBitMask = 8
    
    enum GroundType: Int {
        case grass
        case rock
        case water
        case inTheAir
        case count
    }
    
    // Character handle
    private var characterNode: SCNNode! // top level node
    private var characterOrientation: SCNNode! // the node to rotate to orient the character
    private var model: SCNNode! // the model loaded from the character file
    
    // Physics
    private var characterCollisionShape: SCNPhysicsShape?
    private var collisionShapeOffsetFromModel = float3.zero
    private var downwardAcceleration: Float = 0
    
    // Jump
    private var controllerJump: Bool = false
    private var jumpState: Int = 0
    private var groundNode: SCNNode?
    private var groundNodeLastPosition = float3.zero
    var baseAltitude: Float = 0
    private var targetAltitude: Float = 0
    
    // void playing the step sound too often
    private var lastStepFrame: Int = 0
    private var frameCounter: Int = 0
    
    // Direction
    private var previousUpdateTime: TimeInterval = 0
    private var controllerDirection = float2.zero
    
    // states
    private var attackCount: Int = 0
    private var lastHitTime: TimeInterval = 0
    
    private var shouldResetCharacterPosition = false

    private var spinParticleAttach: SCNNode!

    private var fireEmitterBirthRate: CGFloat = 0.0
    private var smokeEmitterBirthRate: CGFloat = 0.0
    private var whiteSmokeEmitterBirthRate: CGFloat = 0.0

    
    
    private(set) var offsetedMark: SCNNode?
    
    // actions
    var isJump: Bool = false
    var direction = float2()
    var physicsWorld: SCNPhysicsWorld?
    
    // MARK: - Initialization
    init(scene: SCNScene) {
        super.init()

        loadCharacter()
        loadAnimations()
    }

    private func loadCharacter() {
        /// Load character from external file
        let scene = SCNScene( named: "Art.scnassets/character/max.scn")!
        model = scene.rootNode.childNode( withName: "Max_rootNode", recursively: true)
        model.simdPosition = Character.modelOffset

        /* setup character hierarchy
         character
         |_orientationNode
         |_model
         */
        characterNode = SCNNode()
        characterNode.name = "character"
        characterNode.simdPosition = Character.initialPosition

        characterOrientation = SCNNode()
        characterNode.addChildNode(characterOrientation)
        characterOrientation.addChildNode(model)

        let collider = model.childNode(withName: "collider", recursively: true)!
        collider.physicsBody?.collisionBitMask = Int(([ .enemy, .trigger, .collectable ] as Bitmask).rawValue)

        // Setup collision shape
        let (min, max) = model.boundingBox
        let collisionCapsuleRadius = CGFloat(max.x - min.x) * CGFloat(0.4)
        let collisionCapsuleHeight = CGFloat(max.y - min.y)

        let collisionGeometry = SCNCapsule(capRadius: collisionCapsuleRadius, height: collisionCapsuleHeight)
        characterCollisionShape = SCNPhysicsShape(geometry: collisionGeometry, options:[.collisionMargin: Character.collisionMargin])
        collisionShapeOffsetFromModel = float3(0, Float(collisionCapsuleHeight) * 0.51, 0.0)
    }

    private func loadAnimations() {
        let idleAnimation = Character.loadAnimation(fromSceneNamed: "Art.scnassets/character/max_idle.scn")
        model.addAnimationPlayer(idleAnimation, forKey: "idle")
        idleAnimation.play()

        let walkAnimation = Character.loadAnimation(fromSceneNamed: "Art.scnassets/character/max_walk.scn")
        walkAnimation.speed = Character.speedFactor
        walkAnimation.stop()

        
        model.addAnimationPlayer(walkAnimation, forKey: "walk")

        let jumpAnimation = Character.loadAnimation(fromSceneNamed: "Art.scnassets/character/max_jump.scn")
        jumpAnimation.animation.isRemovedOnCompletion = false
        jumpAnimation.stop()
        
        model.addAnimationPlayer(jumpAnimation, forKey: "jump")

        let spinAnimation = Character.loadAnimation(fromSceneNamed: "Art.scnassets/character/max_spin.scn")
        spinAnimation.animation.isRemovedOnCompletion = false
        spinAnimation.speed = 1.5
        spinAnimation.stop()

        model!.addAnimationPlayer(spinAnimation, forKey: "spin")
    }

    var node: SCNNode! {
        return characterNode
    }
        
    func queueResetCharacterPosition() {
        shouldResetCharacterPosition = true
    }
    
    // MARK: - Controlling the character
    
    private var directionAngle: CGFloat = 0.0 {
        didSet {
            characterOrientation.runAction(
                SCNAction.rotateTo(x: 0.0, y: directionAngle, z: 0.0, duration: 0.1, usesShortestUnitArc:true))
        }
    }
    
    func update(atTime time: TimeInterval, with renderer: SCNSceneRenderer) {
        frameCounter += 1
        
        if shouldResetCharacterPosition {
            shouldResetCharacterPosition = false
            resetCharacterPosition()
            return
        }
        
        var characterVelocity = float3.zero
        
        // setup
        var groundMove = float3.zero
        
        // did the ground moved?
        if groundNode != nil {
            let groundPosition = groundNode!.simdWorldPosition
            groundMove = groundPosition - groundNodeLastPosition
        }
        
        characterVelocity = float3(groundMove.x, 0, groundMove.z)
        
        let direction = characterDirection(withPointOfView:renderer.pointOfView)
        
        if previousUpdateTime == 0.0 {
            previousUpdateTime = time
        }
        
        let deltaTime = time - previousUpdateTime
        let characterSpeed = CGFloat(deltaTime) * Character.speedFactor * walkSpeed
        let virtualFrameCount = Int(deltaTime / (1 / 60.0))
        previousUpdateTime = time
        
        // move
        if !direction.allZero() {
            characterVelocity = direction * Float(characterSpeed)
            var runModifier = Float(1.0)
            #if os(OSX)
            if NSEvent.modifierFlags.contains(.shift) {
                runModifier = 2.0
            }
            #endif
            walkSpeed = CGFloat(runModifier * simd_length(direction))
            
            // move character
            directionAngle = CGFloat(atan2f(direction.x, direction.z))
            
            isWalking = true
        } else {
            isWalking = false
        }
        
        // put the character on the ground
        let up = float3(0, 1, 0)
        var wPosition = characterNode.simdWorldPosition
        // gravity
        downwardAcceleration -= Character.gravity
        wPosition.y += downwardAcceleration
        let HIT_RANGE = Float(0.2)
        var p0 = wPosition
        var p1 = wPosition
        p0.y = wPosition.y + up.y * HIT_RANGE
        p1.y = wPosition.y - up.y * HIT_RANGE
        
        let options: [String: Any] = [
            SCNHitTestOption.backFaceCulling.rawValue: false,
            SCNHitTestOption.categoryBitMask.rawValue: Character.collisionMeshBitMask,
            SCNHitTestOption.ignoreHiddenNodes.rawValue: false]
        
        let hitFrom = SCNVector3(p0)
        let hitTo = SCNVector3(p1)
        let hitResult = renderer.scene!.rootNode.hitTestWithSegment(from: hitFrom, to: hitTo, options: options).first
        
        let wasTouchingTheGroup = groundNode != nil
        groundNode = nil
        var touchesTheGround = false
        
        
        if let hit = hitResult {
            let ground = float3(hit.worldCoordinates)
            if wPosition.y <= ground.y + Character.collisionMargin {
                wPosition.y = ground.y + Character.collisionMargin
                if downwardAcceleration < 0 {
                   downwardAcceleration = 0
                }
                groundNode = hit.node
                touchesTheGround = true
                

            }
        } else {
            if wPosition.y < Character.minAltitude {
                wPosition.y = Character.minAltitude
                //reset
                queueResetCharacterPosition()
            }
        }
        
        groundNodeLastPosition = (groundNode != nil) ? groundNode!.simdWorldPosition: float3.zero
        
        //jump -------------------------------------------------------------
        if jumpState == 0 {
            if isJump && touchesTheGround {
                downwardAcceleration += Character.jumpImpulse
                jumpState = 1
                
                model.animationPlayer(forKey: "jump")?.play()
            }
        } else {
            if jumpState == 1 && !isJump {
                jumpState = 2
            }
            
            if downwardAcceleration > 0 {
                for _ in 0..<virtualFrameCount {
                    downwardAcceleration *= jumpState == 1 ? 0.99: 0.2
                }
            }
            
            if touchesTheGround {
                if !wasTouchingTheGroup {
                    model.animationPlayer(forKey: "jump")?.stop(withBlendOutDuration: 0.1)
                    
                    
                }
                
                if !isJump {
                    jumpState = 0
                }
            }
        }
        
        if wPosition.y < characterNode.simdPosition.y {
            wPosition.y = characterNode.simdPosition.y
        }
        //------------------------------------------------------------------
        
        // progressively update the elevation node when we touch the ground
        if touchesTheGround {
            targetAltitude = wPosition.y
        }
        baseAltitude *= 0.95
        baseAltitude += targetAltitude * 0.05
        
        characterVelocity.y += downwardAcceleration
        if simd_length_squared(characterVelocity) > 10E-4 * 10E-4 {
            let startPosition = characterNode!.presentation.simdWorldPosition + collisionShapeOffsetFromModel
            slideInWorld(fromPosition: startPosition, velocity: characterVelocity)
        }
    }
    
    // MARK: - Animating the character
    
    var isAttacking: Bool {
        return attackCount > 0
    }
    
    func attack() {
        attackCount += 1
        model.animationPlayer(forKey: "spin")?.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.attackCount -= 1
        }
        
    }
    
    var isWalking: Bool = false {
        didSet {
            if oldValue != isWalking {
                // Update node animation.
                if isWalking {
                    model.animationPlayer(forKey: "walk")?.play()
                } else {
                    model.animationPlayer(forKey: "walk")?.stop(withBlendOutDuration: 0.2)
                }
            }
        }
    }
    
    var walkSpeed: CGFloat = 1.0 {
        didSet {
            model.animationPlayer(forKey: "walk")?.speed = Character.speedFactor * walkSpeed
        }
    }
    
    func characterDirection(withPointOfView pointOfView: SCNNode?) -> float3 {
        let controllerDir = self.direction
        if controllerDir.allZero() {
            return float3.zero
        }
        
        var directionWorld = float3.zero
        if let pov = pointOfView {
            let p1 = pov.presentation.simdConvertPosition(float3(controllerDir.x, 0.0, controllerDir.y), to: nil)
            let p0 = pov.presentation.simdConvertPosition(float3.zero, to: nil)
            directionWorld = p1 - p0
            directionWorld.y = 0
            if simd_any(directionWorld != float3.zero) {
                let minControllerSpeedFactor = Float(0.2)
                let maxControllerSpeedFactor = Float(1.0)
                let speed = simd_length(controllerDir) * (maxControllerSpeedFactor - minControllerSpeedFactor) + minControllerSpeedFactor
                directionWorld = speed * simd_normalize(directionWorld)
            }
        }
        return directionWorld
    }
    
    func resetCharacterPosition() {
        characterNode.simdPosition = Character.initialPosition
        downwardAcceleration = 0
    }
    
    // MARK: utils
    
    class func loadAnimation(fromSceneNamed sceneName: String) -> SCNAnimationPlayer {
        let scene = SCNScene( named: sceneName )!
        // find top level animation
        var animationPlayer: SCNAnimationPlayer! = nil
        scene.rootNode.enumerateChildNodes { (child, stop) in
            if !child.animationKeys.isEmpty {
                animationPlayer = child.animationPlayer(forKey: child.animationKeys[0])
                stop.pointee = true
            }
        }
        return animationPlayer
    }
    
    // MARK: - physics contact
    func slideInWorld(fromPosition start: float3, velocity: float3) {
        let maxSlideIteration: Int = 4
        var iteration = 0
        var stop: Bool = false

        var replacementPoint = start

        var start = start
        var velocity = velocity
        let options: [SCNPhysicsWorld.TestOption: Any] = [
            SCNPhysicsWorld.TestOption.collisionBitMask: Bitmask.collision.rawValue,
            SCNPhysicsWorld.TestOption.searchMode: SCNPhysicsWorld.TestSearchMode.closest]
        while !stop {
            var from = matrix_identity_float4x4
            from.position = start

            var to: matrix_float4x4 = matrix_identity_float4x4
            to.position = start + velocity

            let contacts = physicsWorld!.convexSweepTest(
                with: characterCollisionShape!,
                from: SCNMatrix4(from),
                to: SCNMatrix4(to),
                options: options)
            if !contacts.isEmpty {
                (velocity, start) = handleSlidingAtContact(contacts.first!, position: start, velocity: velocity)
                iteration += 1

                if simd_length_squared(velocity) <= (10E-3 * 10E-3) || iteration >= maxSlideIteration {
                    replacementPoint = start
                    stop = true
                }
            } else {
                replacementPoint = start + velocity
                stop = true
            }
        }
        characterNode!.simdWorldPosition = replacementPoint - collisionShapeOffsetFromModel
    }

    private func handleSlidingAtContact(_ closestContact: SCNPhysicsContact, position start: float3, velocity: float3)
        -> (computedVelocity: simd_float3, colliderPositionAtContact: simd_float3) {
        let originalDistance: Float = simd_length(velocity)

        let colliderPositionAtContact = start + Float(closestContact.sweepTestFraction) * velocity

        // Compute the sliding plane.
        let slidePlaneNormal = float3(closestContact.contactNormal)
        let slidePlaneOrigin = float3(closestContact.contactPoint)
        let centerOffset = slidePlaneOrigin - colliderPositionAtContact

        // Compute destination relative to the point of contact.
        let destinationPoint = slidePlaneOrigin + velocity

        // We now project the destination point onto the sliding plane.
        let distPlane = simd_dot(slidePlaneOrigin, slidePlaneNormal)

        // Project on plane.
        var t = planeIntersect(planeNormal: slidePlaneNormal, planeDist: distPlane,
                               rayOrigin: destinationPoint, rayDirection: slidePlaneNormal)

        let normalizedVelocity = velocity * (1.0 / originalDistance)
        let angle = simd_dot(slidePlaneNormal, normalizedVelocity)

        var frictionCoeff: Float = 0.3
        if fabs(angle) < 0.9 {
            t += 10E-3
            frictionCoeff = 1.0
        }
        let newDestinationPoint = (destinationPoint + t * slidePlaneNormal) - centerOffset

        // Advance start position to nearest point without collision.
        let computedVelocity = frictionCoeff * Float(1.0 - closestContact.sweepTestFraction)
            * originalDistance * simd_normalize(newDestinationPoint - start)

        return (computedVelocity, colliderPositionAtContact)
    }

}
