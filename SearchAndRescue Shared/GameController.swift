//
//  GameController.swift
//  SearchAndRescue Shared
//
//  Created by Ivan Paulovich on 2020-12-19.
//

import GameController
import GameplayKit
import SceneKit

// Collision bit masks
struct Bitmask: OptionSet {
    let rawValue: Int
    static let character = Bitmask(rawValue: 1 << 0) // the main character
    static let collision = Bitmask(rawValue: 1 << 1) // the ground and walls
    static let enemy = Bitmask(rawValue: 1 << 2) // the enemies
    static let trigger = Bitmask(rawValue: 1 << 3) // the box that triggers camera changes and other actions
    static let collectable = Bitmask(rawValue: 1 << 4) // the collectables (gems and key)
}

typealias ExtraProtocols = SCNSceneRendererDelegate & SCNPhysicsContactDelegate

class GameController: NSObject, ExtraProtocols {

// Global settings
    static let DefaultCameraTransitionDuration = 1.0
    static let NumberOfFiends = 100
    static let CameraOrientationSensitivity: Float = 0.05

    private var scene: SCNScene?
    private weak var sceneRenderer: SCNSceneRenderer?

    // Character
    private var character: Character?

    // Camera and targets
    private var cameraNode = SCNNode()
    private var lookAtTarget = SCNNode()
    private var lastActiveCamera: SCNNode?
    private var lastActiveCameraFrontDirection = simd_float3.zero
    private var activeCamera: SCNNode?
    private var playingCinematic: Bool = false

    //triggers
    private var lastTrigger: SCNNode?
    private var firstTriggerDone: Bool = false

    //enemies
    private var enemy1: SCNNode?
    private var enemy2: SCNNode?

    //friends
    private var friends = [SCNNode](repeating: SCNNode(), count: NumberOfFiends)
    private var friendsSpeed = [Float](repeating: 0.0, count: NumberOfFiends)
    private var friendCount: Int = 0
    private var friendsAreFree: Bool = false

    //collected objects
    private var collectedKeys: Int = 0
    private var collectedGems: Int = 0
    private var keyIsVisible: Bool = false



    // GameplayKit
    private var gkScene: GKScene?

    // Game controller
    private var gamePadCurrent: GCController?
    private var gamePadLeft: GCControllerDirectionPad?
    private var gamePadRight: GCControllerDirectionPad?

    // update delta time
    private var lastUpdateTime = TimeInterval()

// MARK: -
// MARK: Setup

    func setupCharacter() {
        character = Character(scene: scene!)

        // keep a pointer to the physicsWorld from the character because we will need it when updating the character's position
        character!.physicsWorld = scene!.physicsWorld
        scene!.rootNode.addChildNode(character!.node!)
    }

    func setupPhysics() {
        //make sure all objects only collide with the character
        self.scene?.rootNode.enumerateHierarchy({(_ node: SCNNode, _ _: UnsafeMutablePointer<ObjCBool>) -> Void in
            node.physicsBody?.collisionBitMask = Int(Bitmask.character.rawValue)
        })
    }

    func setupCollisions() {
        // load the collision mesh from another scene and merge into main scene
        let collisionsScene = SCNScene( named: "Art.scnassets/collision.scn" )
        collisionsScene!.rootNode.enumerateChildNodes { (_ child: SCNNode, _ _: UnsafeMutablePointer<ObjCBool>) in
            child.opacity = 0.0
            self.scene?.rootNode.addChildNode(child)
        }
    }

    // the follow camera behavior make the camera to follow the character, with a constant distance, altitude and smoothed motion
    func setupFollowCamera(_ cameraNode: SCNNode) {
        // look at "lookAtTarget"
        let lookAtConstraint = SCNLookAtConstraint(target: self.lookAtTarget)
        lookAtConstraint.influenceFactor = 0.07
        lookAtConstraint.isGimbalLockEnabled = true

        // distance constraints
        let follow = SCNDistanceConstraint(target: self.lookAtTarget)
        let distance = CGFloat(simd_length(cameraNode.simdPosition))
        follow.minimumDistance = distance
        follow.maximumDistance = distance

        // configure a constraint to maintain a constant altitude relative to the character
        let desiredAltitude = abs(cameraNode.simdWorldPosition.y)
        weak var weakSelf = self

        let keepAltitude = SCNTransformConstraint.positionConstraint(inWorldSpace: true, with: {(_ node: SCNNode, _ position: SCNVector3) -> SCNVector3 in
                guard let strongSelf = weakSelf else { return position }
                var position = float3(position)
                position.y = strongSelf.character!.baseAltitude + desiredAltitude
                return SCNVector3( position )
            })

        let accelerationConstraint = SCNAccelerationConstraint()
        accelerationConstraint.maximumLinearVelocity = 1500.0
        accelerationConstraint.maximumLinearAcceleration = 50.0
        accelerationConstraint.damping = 0.05

        // use a custom constraint to let the user orbit the camera around the character
        let transformNode = SCNNode()
        let orientationUpdateConstraint = SCNTransformConstraint(inWorldSpace: true) { (_ node: SCNNode, _ transform: SCNMatrix4) -> SCNMatrix4 in
            guard let strongSelf = weakSelf else { return transform }
            if strongSelf.activeCamera != node {
                return transform
            }

            // Slowly update the acceleration constraint influence factor to smoothly reenable the acceleration.
            accelerationConstraint.influenceFactor = min(1, accelerationConstraint.influenceFactor + 0.01)

            let targetPosition = strongSelf.lookAtTarget.presentation.simdWorldPosition
            let cameraDirection = strongSelf.cameraDirection
            if cameraDirection.allZero() {
                return transform
            }

            // Disable the acceleration constraint.
            accelerationConstraint.influenceFactor = 0

            let characterWorldUp = strongSelf.character?.node?.presentation.simdWorldUp

            transformNode.transform = transform

            let q = simd_mul(
                simd_quaternion(GameController.CameraOrientationSensitivity * cameraDirection.x, characterWorldUp!),
                simd_quaternion(GameController.CameraOrientationSensitivity * cameraDirection.y, transformNode.simdWorldRight)
            )

            transformNode.simdRotate(by: q, aroundTarget: targetPosition)
            return transformNode.transform
        }

        cameraNode.constraints = [follow, keepAltitude, accelerationConstraint, orientationUpdateConstraint, lookAtConstraint]
    }

    // the axis aligned behavior look at the character but remains aligned using a specified axis
    func setupAxisAlignedCamera(_ cameraNode: SCNNode) {
        let distance: Float = simd_length(cameraNode.simdPosition)
        let originalAxisDirection = cameraNode.simdWorldFront

        self.lastActiveCameraFrontDirection = originalAxisDirection

        let symetricAxisDirection = simd_make_float3(-originalAxisDirection.x, originalAxisDirection.y, -originalAxisDirection.z)

        weak var weakSelf = self

        // define a custom constraint for the axis alignment
        let axisAlignConstraint = SCNTransformConstraint.positionConstraint(
            inWorldSpace: true, with: {(_ node: SCNNode, _ position: SCNVector3) -> SCNVector3 in
                guard let strongSelf = weakSelf else { return position }
                guard let activeCamera = strongSelf.activeCamera else { return position }

                let axisOrigin = strongSelf.lookAtTarget.presentation.simdWorldPosition
                let referenceFrontDirection =
                    strongSelf.activeCamera == node ? strongSelf.lastActiveCameraFrontDirection : activeCamera.presentation.simdWorldFront

                let axis = simd_dot(originalAxisDirection, referenceFrontDirection) > 0 ? originalAxisDirection: symetricAxisDirection

                let constrainedPosition = axisOrigin - distance * axis
                return SCNVector3(constrainedPosition)
            })

        let accelerationConstraint = SCNAccelerationConstraint()
        accelerationConstraint.maximumLinearAcceleration = 20
        accelerationConstraint.decelerationDistance = 0.5
        accelerationConstraint.damping = 0.05

        // look at constraint
        let lookAtConstraint = SCNLookAtConstraint(target: self.lookAtTarget)
        lookAtConstraint.isGimbalLockEnabled = true // keep horizon horizontal

        cameraNode.constraints = [axisAlignConstraint, lookAtConstraint, accelerationConstraint]
    }

    func setupCameraNode(_ node: SCNNode) {
        guard let cameraName = node.name else { return }

        if cameraName.hasPrefix("camTrav") {
            setupAxisAlignedCamera(node)
        } else if cameraName.hasPrefix("camLookAt") {
            setupFollowCamera(node)
        }
    }

    func setupCamera() {
        //The lookAtTarget node will be placed slighlty above the character using a constraint
        weak var weakSelf = self

        self.lookAtTarget.constraints = [ SCNTransformConstraint.positionConstraint(
                                        inWorldSpace: true, with: { (_ node: SCNNode, _ position: SCNVector3) -> SCNVector3 in
            guard let strongSelf = weakSelf else { return position }

            guard var worldPosition = strongSelf.character?.node?.simdWorldPosition else { return position }
            worldPosition.y = strongSelf.character!.baseAltitude + 0.5
            return SCNVector3(worldPosition)
        })]

        self.scene?.rootNode.addChildNode(lookAtTarget)

        self.scene?.rootNode.enumerateHierarchy({(_ node: SCNNode, _ _: UnsafeMutablePointer<ObjCBool>) -> Void in
            if node.camera != nil {
                self.setupCameraNode(node)
            }
        })

        self.cameraNode.camera = SCNCamera()
        self.cameraNode.name = "mainCamera"
        self.cameraNode.camera!.zNear = 0.1
        self.scene!.rootNode.addChildNode(cameraNode)

        setActiveCamera("camLookAt_cameraGame", animationDuration: 0.0)
    }

    func loadParticleSystems(atPath path: String) -> [SCNParticleSystem] {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()

        let fileName = url.lastPathComponent
        let ext: String = url.pathExtension

        if ext == "scnp" {
            return [SCNParticleSystem(named: fileName, inDirectory: directory.relativePath)!]
        } else {
            var particles = [SCNParticleSystem]()
            let scene = SCNScene(named: fileName, inDirectory: directory.relativePath, options: nil)
            scene!.rootNode.enumerateHierarchy({(_ node: SCNNode, _ _: UnsafeMutablePointer<ObjCBool>) -> Void in
                if node.particleSystems != nil {
                    particles += node.particleSystems!
                }
            })
            return particles
        }
    }


    func setupPlatforms() {
        let PLATFORM_MOVE_OFFSET = Float(1.5)
        let PLATFORM_MOVE_SPEED = Float(0.5)

        var alternate: Float = 1
        // This could be done in the editor using the action editor.
        scene!.rootNode.enumerateHierarchy({(_ node: SCNNode, _ _: UnsafeMutablePointer<ObjCBool>) -> Void in
            if node.name == "mobilePlatform" && !node.childNodes.isEmpty {
                node.simdPosition = simd_float3(
                    node.simdPosition.x - (alternate * PLATFORM_MOVE_OFFSET / 2.0), node.simdPosition.y, node.simdPosition.z)

                let moveAction = SCNAction.move(by: SCNVector3(alternate * PLATFORM_MOVE_OFFSET, 0, 0),
                                                duration: TimeInterval(1 / PLATFORM_MOVE_SPEED))
                moveAction.timingMode = .easeInEaseOut
                node.runAction(SCNAction.repeatForever(SCNAction.sequence([moveAction, moveAction.reversed()])))

                alternate = -alternate // alternate movement of platforms to desynchronize them

                node.enumerateChildNodes({ (_ child: SCNNode, _ _: UnsafeMutablePointer<ObjCBool>) in
                    if child.name == "particles_platform" {
                        child.particleSystems?[0].orientationDirection = SCNVector3(0, 1, 0)
                    }
                })
            }
        })
    }

    // MARK: - Camera transitions

    // transition to the specified camera
    // this method will reparent the main camera under the camera named "cameraNamed"
    // and trigger the animation to smoothly move from the current position to the new position
    func setActiveCamera(_ cameraName: String, animationDuration duration: CFTimeInterval) {
        guard let camera = scene?.rootNode.childNode(withName: cameraName, recursively: true) else { return }
        if self.activeCamera == camera {
            return
        }

        self.lastActiveCamera = activeCamera
        if activeCamera != nil {
            self.lastActiveCameraFrontDirection = (activeCamera?.presentation.simdWorldFront)!
        }
        self.activeCamera = camera

        // save old transform in world space
        let oldTransform: SCNMatrix4 = cameraNode.presentation.worldTransform

        // re-parent
        camera.addChildNode(cameraNode)

        // compute the old transform relative to our new parent node (yeah this is the complex part)
        let parentTransform = camera.presentation.worldTransform
        let parentInv = SCNMatrix4Invert(parentTransform)

        // with this new transform our position is unchanged in workd space (i.e we did re-parent but didn't move).
        cameraNode.transform = SCNMatrix4Mult(oldTransform, parentInv)

        // now animate the transform to identity to smoothly move to the new desired position
        SCNTransaction.begin()
        SCNTransaction.animationDuration = duration
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: CAMediaTimingFunctionName.easeInEaseOut)
        cameraNode.transform = SCNMatrix4Identity

        if let cameraTemplate = camera.camera {
            cameraNode.camera!.fieldOfView = cameraTemplate.fieldOfView
            cameraNode.camera!.wantsDepthOfField = cameraTemplate.wantsDepthOfField
            cameraNode.camera!.sensorHeight = cameraTemplate.sensorHeight
            cameraNode.camera!.fStop = cameraTemplate.fStop
            cameraNode.camera!.focusDistance = cameraTemplate.focusDistance
            cameraNode.camera!.bloomIntensity = cameraTemplate.bloomIntensity
            cameraNode.camera!.bloomThreshold = cameraTemplate.bloomThreshold
            cameraNode.camera!.bloomBlurRadius = cameraTemplate.bloomBlurRadius
            cameraNode.camera!.wantsHDR = cameraTemplate.wantsHDR
            cameraNode.camera!.wantsExposureAdaptation = cameraTemplate.wantsExposureAdaptation
            cameraNode.camera!.vignettingPower = cameraTemplate.vignettingPower
            cameraNode.camera!.vignettingIntensity = cameraTemplate.vignettingIntensity
        }
        SCNTransaction.commit()
    }

    func setActiveCamera(_ cameraName: String) {
        setActiveCamera(cameraName, animationDuration: GameController.DefaultCameraTransitionDuration)
    }

    

    // MARK: - Init

    init(scnView: SCNView) {
        super.init()
        
        sceneRenderer = scnView
        sceneRenderer!.delegate = self
        
        // Uncomment to show statistics such as fps and timing information
        //scnView.showsStatistics = true

        //load the main scene
        self.scene = SCNScene(named: "Art.scnassets/scene.scn")

        //setup physics
        setupPhysics()

        //setup collisions
        setupCollisions()

        //load the character
        setupCharacter()


        //setup platforms
        setupPlatforms()



        //setup lighting
        let light = scene!.rootNode.childNode(withName: "DirectLight", recursively: true)!.light
        light!.shadowCascadeCount = 3  // turn on cascade shadows
        light!.shadowMapSize = CGSize(width: CGFloat(512), height: CGFloat(512))
        light!.maximumShadowDistance = 20
        light!.shadowCascadeSplittingFactor = 0.5
        
        //setup camera
        setupCamera()

        //assign the scene to the view
        sceneRenderer!.scene = self.scene

        

        //select the point of view to use
        sceneRenderer!.pointOfView = self.cameraNode

        //register ourself as the physics contact delegate to receive contact notifications
        sceneRenderer!.scene!.physicsWorld.contactDelegate = self
    }

    func resetPlayerPosition() {
        character!.queueResetCharacterPosition()
    }

    // MARK: - cinematic

    func startCinematic() {
        playingCinematic = true
        character!.node!.isPaused = true
    }

    func stopCinematic() {
        playingCinematic = false
        character!.node!.isPaused = false
    }

    

    // MARK: - Controlling the character

    func controllerJump(_ controllerJump: Bool) {
        character!.isJump = controllerJump
    }

    func controllerAttack() {
        if !self.character!.isAttacking {
            self.character!.attack()
        }
    }

    var characterDirection: vector_float2 {
        get {
            return character!.direction
        }
        set {
            var direction = newValue
            let l = simd_length(direction)
            if l > 1.0 {
                direction *= 1 / l
            }
            character!.direction = direction
        }
    }

    var cameraDirection = vector_float2.zero {
        didSet {
            let l = simd_length(cameraDirection)
            if l > 1.0 {
                cameraDirection *= 1 / l
            }
            cameraDirection.y = 0
        }
    }
    
    // MARK: - Update

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        // compute delta time
        if lastUpdateTime == 0 {
            lastUpdateTime = time
        }
        
        lastUpdateTime = time

        // stop here if cinematic
        if playingCinematic == true {
            return
        }

        // update characters
        character!.update(atTime: time, with: renderer)
    }

    // MARK: - Configure rendering quality

    func turnOffEXRForMAterialProperty(property: SCNMaterialProperty) {
        if var propertyPath = property.contents as? NSString {
            if propertyPath.pathExtension == "exr" {
                propertyPath = ((propertyPath.deletingPathExtension as NSString).appendingPathExtension("png")! as NSString)
                property.contents = propertyPath
            }
        }
    }

    func turnOffEXR() {
        self.turnOffEXRForMAterialProperty(property: scene!.background)
        self.turnOffEXRForMAterialProperty(property: scene!.lightingEnvironment)

        scene?.rootNode.enumerateChildNodes { (child: SCNNode, _: UnsafeMutablePointer<ObjCBool>) in
            if let materials = child.geometry?.materials {
                for material in materials {
                    self.turnOffEXRForMAterialProperty(property: material.selfIllumination)
                }
            }
        }
    }

    func turnOffNormalMaps() {
        scene?.rootNode.enumerateChildNodes({ (child: SCNNode, _: UnsafeMutablePointer<ObjCBool>) in
            if let materials = child.geometry?.materials {
                for material in materials {
                    material.normal.contents = SKColor.black
                }
            }
        })
    }

    func turnOffHDR() {
        scene?.rootNode.enumerateChildNodes({ (child: SCNNode, _: UnsafeMutablePointer<ObjCBool>) in
            child.camera?.wantsHDR = false
        })
    }

    func turnOffDepthOfField() {
        scene?.rootNode.enumerateChildNodes({ (child: SCNNode, _: UnsafeMutablePointer<ObjCBool>) in
            child.camera?.wantsDepthOfField = false
        })
    }

    func turnOffSoftShadows() {
        scene?.rootNode.enumerateChildNodes({ (child: SCNNode, _: UnsafeMutablePointer<ObjCBool>) in
            if let lightSampleCount = child.light?.shadowSampleCount {
                child.light?.shadowSampleCount = min(lightSampleCount, 1)
            }
        })
    }

    func turnOffPostProcess() {
        scene?.rootNode.enumerateChildNodes({ (child: SCNNode, _: UnsafeMutablePointer<ObjCBool>) in
            if let light = child.light {
                light.shadowCascadeCount = 0
                light.shadowMapSize = CGSize(width: 1024, height: 1024)
            }
        })
    }

    func turnOffOverlay() {
        sceneRenderer?.overlaySKScene = nil
    }

    func turnOffVertexShaderModifiers() {
        scene?.rootNode.enumerateChildNodes({ (child: SCNNode, _: UnsafeMutablePointer<ObjCBool>) in
            if var shaderModifiers = child.geometry?.shaderModifiers {
                shaderModifiers[SCNShaderModifierEntryPoint.geometry] = nil
                child.geometry?.shaderModifiers = shaderModifiers
            }

            if let materials = child.geometry?.materials {
                for material in materials where material.shaderModifiers != nil {
                    var shaderModifiers = material.shaderModifiers!
                    shaderModifiers[SCNShaderModifierEntryPoint.geometry] = nil
                    material.shaderModifiers = shaderModifiers
                }
            }
        })
    }

    func turnOffVegetation() {
        scene?.rootNode.enumerateChildNodes({ (child: SCNNode, _: UnsafeMutablePointer<ObjCBool>) in
            guard let materialName = child.geometry?.firstMaterial?.name as NSString? else { return }
            if materialName.hasPrefix("plante") {
                child.isHidden = true
            }
        })
    }


    // MARK: - Debug menu

    func fStopChanged(_ value: CGFloat) {
        sceneRenderer!.pointOfView!.camera!.fStop = value
    }

    func focusDistanceChanged(_ value: CGFloat) {
        sceneRenderer!.pointOfView!.camera!.focusDistance = value
    }

    func debugMenuSelectCameraAtIndex(_ index: Int) {
        if index == 0 {
            let key = self.scene?.rootNode .childNode(withName: "key", recursively: true)
            key?.opacity = 1.0
        }
        self.setActiveCamera("CameraDof\(index)")
    }








}
